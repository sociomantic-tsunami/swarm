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
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.neo.node.ConnectionHandler;

/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.transition;
import ocean.net.server.connection.IConnectionHandler;
import ocean.sys.socket.AddressIPSocket;
import ocean.util.log.Logger;

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
    import ocean.time.StopWatch;

    import ClassicSwarm =
        swarm.node.connection.ConnectionHandler: ConnectionSetupParams;

    import ocean.transition;

    /// Map of request handling info indexed by command code.
    public struct RequestMap
    {
        import swarm.node.request.RequestStats;

        /***********************************************************************

            Definition of a command handler function. It is called when a new
            incoming request is handled and runs in its own fiber (the fiber
            owned by the passed RequestOnConn instance).

            Params:
                shared_resources = an opaque object containing resources owned
                    by the node which are required by the request
                connection = manages the connection socket I/O and the fiber
                cmdver = the command version
                msg_payload = the payload of the first message for the request

        ***********************************************************************/

        public alias void function ( Object shared_resources,
            RequestOnConn connection, Command.Version cmdver,
            Const!(void)[] msg_payload ) Handler;

        /// Details stored in map about a single request.
        public struct RequestInfo
        {
            /// The name of the request, used for stats tracking.
            istring name;

            /// The request handler function, called when a request of this type
            /// is initiated.
            Handler handler;

            /// Indicates whether timing stats should be gathered about the
            /// request.
            bool timing;
        }

        /// Map of request info by command code.
        private RequestInfo[Command.Code] map;

        /***********************************************************************

            Adds a request to the map.

            Params:
                code = command code to initiate request
                name = name of request
                handler = function called to handle this request type
                timing = if true, timing stats about request of this type are
                    tracked

        ***********************************************************************/

        public void add ( Command.Code code, cstring name, Handler handler,
            bool timing = true )
        {
            this.map[code] = RequestInfo(idup(name), handler, timing);
        }

        /***********************************************************************

            Adds an unnamed request to the map. (This method exists in order to
            mimic the API of an associative array, for compatibility with old
            code.)

            Params:
                handler = function called to handle this request type
                code = command code to initiate request

        ***********************************************************************/

        deprecated("Use the `add` method instead, specifying a name for the request.")
        public void opIndexAssign ( Handler handler, Command.Code code )
        {
            this.map[code] = RequestInfo(null, handler, true);
        }

        /***********************************************************************

            Sets up stats tracking for all requests in the map.

            Params:
                request_stats = neo request stats tracking object

        ***********************************************************************/

        public void initStats ( RequestStats request_stats )
        {
            foreach ( code, rq; this.map )
                if ( rq.name.length > 0 )
                    request_stats.init(rq.name, rq.timing);
        }
    }

    /// Alias to old name.
    deprecated("Use the `RequestMap` struct instead.")
    public alias RequestMap CmdHandlers;

    /***************************************************************************

        Connection handler shared parameters class. Passed to the constructor.

    ***************************************************************************/

    public static class SharedParams
    {
        import ocean.io.select.EpollSelectDispatcher;

        import swarm.neo.authentication.CredentialsFile;
        import swarm.neo.authentication.HmacDef: Key;
        import swarm.node.model.INodeInfo;

        /***********************************************************************

            Map of command codes -> request handling info.

        ***********************************************************************/

        public RequestMap requests;

        /// Alias to old name.
        deprecated("Use the `requests` member instead.")
        public alias requests cmd_handlers;

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

            Node info interface. Used to get access to the neo request stats
            tracker.

        ***********************************************************************/

        public INodeInfo node_info;

        /***********************************************************************

            Constructor.

            Note that `unix_socket_path.length` needs to be less than
            `UNIX_PATH_MAX`, a constant defined in `ocean.stdc.posix.sys.un`.

            Params:
                epoll = epoll dispatcher used by the node
                shared_resources = global resources shared by all request
                    handlers
                requests = map of command code -> request handling info
                no_delay = if false, data written to the socket will be buffered
                    and sent according to Nagle's algorithm. If true, no
                    buffering will occur. (The no-delay option is not generally
                    suited to live servers, where efficient packing of packets
                    is desired, but can be useful for low-bandwidth test setups.)
                credentials = map of auth names -> keys
                node_info = node informational interface

        ***********************************************************************/

        public this ( EpollSelectDispatcher epoll, Object shared_resources,
            RequestMap requests, bool no_delay,
            ref Const!(Key[istring]) credentials, INodeInfo node_info )
        {
            assert(requests.map.length > 0);

            this.epoll = epoll;
            this.shared_resources = shared_resources;
            this.request_pool = new Connection.RequestPool;
            this.yielded_rqonconns = new Connection.YieldedRequestOnConns;
            epoll.register(this.yielded_rqonconns);
            this.requests = requests;
            this.requests.map.rehash;
            this.no_delay = no_delay;
            this.credentials = &credentials;
            this.node_info = node_info;
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

        Returns:
            the number of bytes sent over the connection since the last call to
            this method

    ***************************************************************************/

    public ulong bytes_sent ( )
    {
        return this.connection.getIOStats(true, true).socket.total;
    }

    /***************************************************************************

        Returns:
            the number of bytes received over the connection since the last call
            to this method

    ***************************************************************************/

    public ulong bytes_received ( )
    {
        return this.connection.getIOStats(false, true).socket.total;
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

            if (auto rq = command.code in this.shared_params.requests.map)
            {
                this.handleRequest(command, *rq, connection, init_payload);
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

        Called when an incoming supported request is to be handled. Runs in the
        fiber of `connection`.

        Params:
            command = request/version code read from the client
            rq = request info struct (including handler function)
            connection = manages the connection socket I/O and the fiber
            init_payload = the payload of the first message for the request

    ***************************************************************************/

    private void handleRequest ( Command command, RequestMap.RequestInfo rq,
        RequestOnConn connection, Const!(void)[] init_payload )
    {
        StopWatch timer;

        if ( rq.name )
        {
            this.shared_params.node_info.neo_request_stats
                .started(rq.name);

            if ( rq.timing )
                timer.start();
        }

        scope ( exit )
        {
            if ( rq.name )
            {
                if ( rq.timing )
                    this.shared_params.node_info.neo_request_stats
                        .finished(rq.name, timer.microsec);
                else
                    this.shared_params.node_info.neo_request_stats
                        .finished(rq.name);
            }
        }

        try
        {
            (*rq.handler)(this.shared_params.shared_resources,
                connection, command.ver, init_payload);
        }
        catch ( Exception e )
        {
            log.error("{}:{}: Exception thrown from request handler: {} @ {}:{}",
                this.connection.connected_client, rq.name,
                getMsg(e), e.file, e.line);
            throw e;
        }
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
                auto code = SupportedStatus.RequestNotSupported;
                payload.add(code);
            }
        );
    }
}
