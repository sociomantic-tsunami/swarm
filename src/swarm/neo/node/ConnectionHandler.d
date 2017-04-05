/*******************************************************************************

    Fiber-based node connection handler class

    The node connection handler class is designed to be managed by an instance
    of SelectListener, which keeps a pool of connection handlers, listens
    for incoming connections, then assigns a new connection to a connection
    handler in the pool.

    The connection handler class handles reading the command code from the
    client, checking whether it is a valid command, then selecting from a set of
    request handler objects and assigning the request to the appropriate
    handler. Once a command has finished processing, the connection handler
    tries to read the next command from the client.

    copyright: Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.node.ConnectionHandler;

/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.net.server.connection.IConnectionHandler;
import ocean.sys.socket.AddressIPSocket;
import ocean.util.log.Log;

/*******************************************************************************

    Static module logger

*******************************************************************************/

private Logger log;
static this ( )
{
    log = Log.lookup("swarm.neo.node.ConnectionHandler");
}

/******************************************************************************/

class ConnectionHandler : IConnectionHandler
{
    import swarm.neo.node.Connection;
    import swarm.neo.node.RequestOnConn;
    import swarm.neo.request.Command;

    import ocean.io.select.EpollSelectDispatcher;

    import ClassicSwarm =
        swarm.node.connection.ConnectionHandler: ConnectionSetupParams;

    import ocean.transition;

    /***************************************************************************

        Definition of a command handler function. It is called when a new
        incoming request is handled and runs in its own fiber (the fiber
        owned by the passed RequestOnConn instance).

        Params:
            shared_resources = an opaque object containing resources owned by
                the node which are required by the request
            connection   = manages the connection socket I/O and the fiber
            cmdver       = the command version
            msg_payload = the payload of the first message for the request

    ***************************************************************************/

    public alias void function ( Object shared_resources,
        RequestOnConn connection, Command.Version cmdver,
        Const!(void)[] msg_payload ) CommandHandler;

    /***************************************************************************

        Table of handler functions by command.

    ***************************************************************************/

    public alias CommandHandler[Command.Code] CmdHandlers;

    /***************************************************************************

        Connection handler shared parameters class. Passed to the constructor.

    ***************************************************************************/

    public static class SharedParams
    {
        import ocean.io.select.EpollSelectDispatcher;

        import swarm.neo.authentication.CredentialsFile;
        import swarm.neo.authentication.HmacDef: Key;

        /***********************************************************************

            Map of command codes -> handler functions.

        ***********************************************************************/

        public CmdHandlers cmd_handlers;

        /***********************************************************************

            Epoll instance used by the node.

        ***********************************************************************/

        public EpollSelectDispatcher epoll;

        /***********************************************************************

            Pointer to the map of auth names -> keys.

        ***********************************************************************/

        public Const!(Key[istring])* credentials;

        /***********************************************************************

            Pool for `Request` objects, shared across all connections.

        ***********************************************************************/

        public Connection.RequestPool request_pool;

        /***********************************************************************

            Global resumer to resume yielded `RequestOnConn`s

        ***********************************************************************/

        public Connection.YieldedRequestOnConns yielded_rqonconns;

        /***********************************************************************

            Opaque shared resources instance passed to the request handlers.

        ***********************************************************************/

        public Object shared_resources;

        /***********************************************************************

            Flag controlling whether Nagle's algorithm is disabled (true) or
            left enabled (false) on the underlying socket.

            (The no-delay option is not generally suited to live servers, where
            efficient packing of packets is desired, but can be useful for
            low-bandwidth test setups.)

        ***********************************************************************/

        public bool no_delay;

        /***********************************************************************

            Constructor.

            Note that `unix_socket_path.length` needs to be less than
            `UNIX_PATH_MAX`, a constant defined in `ocean.stdc.posix.sys.un`.

            Params:
                epoll = epoll dispatcher used by the node
                shared_resources = global resources shared by all request
                    handlers
                cmd_handlers = table of handler functions by command
                no_delay = if false, data written to the socket will be buffered
                    and sent according to Nagle's algorithm. If true, no
                    buffering will occur. (The no-delay option is not generally
                    suited to live servers, where efficient packing of packets
                    is desired, but can be useful for low-bandwidth test setups.)
                credentials = map of auth names -> keys

        ***********************************************************************/

        public this ( EpollSelectDispatcher epoll, Object shared_resources,
            CmdHandlers cmd_handlers, bool no_delay,
            ref Const!(Key[istring]) credentials )
        {
            this.epoll = epoll;
            this.shared_resources = shared_resources;
            this.request_pool = new Connection.RequestPool;
            this.yielded_rqonconns = new Connection.YieldedRequestOnConns;
            epoll.register(this.yielded_rqonconns);
            this.cmd_handlers = cmd_handlers.rehash;
            this.no_delay = no_delay;
            this.credentials = &credentials;
        }
    }

    /***************************************************************************

        Low-level I/O handler and message parser.

    ***************************************************************************/

    private Connection connection;

    /***************************************************************************

        Parameters shared across all instances of this class.

    ***************************************************************************/

    private SharedParams shared_params;

    /***************************************************************************

        Returns this instance to the `SelectListener` pool of connection
        handlers.

    ***************************************************************************/

    private FinalizeDg return_to_pool;

    /***************************************************************************

        Constructor.

        Params:
            return_to_pool = delegate to be called when this instance should be
                recycled to the `SelectListener`'s pool of connection handlers
            shared_params = parameters shared across all instances of this class

    ***************************************************************************/

    public this ( FinalizeDg return_to_pool, SharedParams shared_params )
    {
        auto socket = new AddressIPSocket!();
        super(socket, null, null);

        this.connection = new Connection(
            *shared_params.credentials, socket, shared_params.epoll,
            &this.handleRequest, &this.whenConnectionClosed,
            shared_params.request_pool, shared_params.yielded_rqonconns,
            shared_params.no_delay
        );
        this.return_to_pool = return_to_pool;
        this.shared_params = shared_params;
    }

    /***************************************************************************

        Returns this instance to the `SelectListener` pool of connection
        handlers. Called from the Connection.

    ***************************************************************************/

    private void whenConnectionClosed ( )
    {
        this.return_to_pool(this);
    }

    /***************************************************************************

        Called by IFiberConnectionHandler when a new connection is established
        by a client.

        Performs authentication, if required, then reads the command sent by the
        client and calls the handleRequest() method.

    ***************************************************************************/

    override public void handleConnection ( )
    {
        this.connection.start();
    }

    /***************************************************************************

        Called when a new request was created, runs in the fiber of
        `connection`. Parses the command in `init_payload`, and calls the
        function that is registered in `cmd_handlers` for that command.

        If the parsed command is not supported by the node (i.e. no handler
        exists for it in `cmd_handlers`), the RequestNotSupported status code is
        sent to the client. If a command cannot be parsed from the payload, the
        connection is shutdown with a protocol error.

        Params:
            connection   = manages the connection socket I/O and the fiber
            init_payload = the payload of the first message for the request

    ***************************************************************************/

    protected void handleRequest ( RequestOnConn connection, Const!(void)[] init_payload = null )
    {
        if (init_payload.length >= Command.sizeof)
        {
            auto command = *this.connection.message_parser.getValue!(Command)(init_payload);

            if (auto cmd_handler =
                command.code in this.shared_params.cmd_handlers)
            {
                try
                {
                    (*cmd_handler)(this.shared_params.shared_resources,
                        connection, command.ver, init_payload);
                }
                catch ( Exception e )
                {
                    log.error("Exception thrown from request handler: {} @ {}:{}",
                        getMsg(e), e.file, e.line);
                    throw e;
                }
            }
            else
            {
                this.unsupportedRequest(connection);
            }
        }
        else
        {
            connection.event_dispatcher.shutdownWithProtocolError(
                "First request message contains no command"
            );
        }
    }

    /***************************************************************************

        Required by the base class, but always returns false. We know that the
        socket is shut down, on error, by ConnectionBase (the send fiber's
        fiberMethod() catches exceptions and calls
        ConnectionBase.shutdownImpl()).

        Returns:
            always false, indicating that the socket has already been shut down
            and should not be shut down again in super.finalize()

    ***************************************************************************/

    override protected bool io_error ( )
    {
        return false;
    }

    /***************************************************************************

        Sends the status code RequestNotSupported to the client.

        Params:
            connection = connection to send the status code to

    ***************************************************************************/

    private void unsupportedRequest ( RequestOnConn connection )
    {
        auto ed = connection.event_dispatcher;
        ed.send(
            ( ed.Payload payload )
            {
                auto code = GlobalStatusCode.RequestNotSupported;
                payload.add(code);
            }
        );
    }
}
