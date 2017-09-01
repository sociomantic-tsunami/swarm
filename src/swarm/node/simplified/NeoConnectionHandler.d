/*******************************************************************************

    Neo protocol connection handler class.

    The connection handler class is designed to be managed by an instance of
    SelectListener, which keeps a pool of connection handlers, listens for
    incoming connections, then assigns a new connection to a connection handler
    in the pool.

    Messages received over the connection are passed to the connection handler
    class, which reads the command code and version, checks whether the
    specified command and version are supported, then calls the appropriate
    request handler from a map of handler functions.

    TODO: this module is a replacement of the deprecated
    swarm.neo.node.ConnectionHandler. The one difference is that this class has
    a simple reference to the node to which it belongs, rather than all node
    information being copied into a "connection setup params" object. When the
    deprecated module is removed, this module may be moved into its place.

    copyright:
        Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.node.simplified.NeoConnectionHandler;

import ocean.net.server.connection.IConnectionHandler;
import ocean.util.log.Log;
import swarm.node.simplified.NodeBase;

/// ditto
public class NeoConnectionHandler : IConnectionHandler
{
    import swarm.neo.node.Connection;
    import swarm.neo.node.RequestOnConn;
    import swarm.neo.request.Command;

    import ocean.transition;
    import ocean.io.select.EpollSelectDispatcher;
    import ocean.sys.socket.AddressIPSocket;

    /// Low-level I/O handler and message parser.
    private Connection connection;

    /// Reference to the node which owns this connection.
    private NodeBase node;

    /// Delegate (passed to ctor) to call in order to return this instance to
    /// the `SelectListener` pool of connection handlers.
    private FinalizeDg return_to_pool;

    /***************************************************************************

        Constructor.

        Params:
            return_to_pool = delegate to be called when this instance should be
                recycled to the `SelectListener`'s pool of connection handlers
            node = node which owns this connection

    ***************************************************************************/

    public this ( FinalizeDg return_to_pool, NodeBase node )
    {
        auto socket = new AddressIPSocket!();
        super(socket, null, null);

        this.connection = new Connection(
            *node.neo.credentials, socket, node.epoll,
            &this.handleRequest, &this.whenConnectionClosed,
            node.neo.request_pool, node.neo.yielded_rqonconns,
            node.neo.no_delay
        );
        this.return_to_pool = return_to_pool;
        this.node = node;
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

    protected void handleRequest ( RequestOnConn connection,
        Const!(void)[] init_payload = null )
    {
        if (init_payload.length >= Command.sizeof)
        {
            auto command = *this.connection.message_parser.getValue!(Command)(init_payload);

            if (auto cmd_handler =
                command.code in this.node.neo.cmd_handlers)
            {
                try
                {
                    (*cmd_handler)(this.node.neo.shared_resources,
                        connection, command.ver, init_payload);
                }
                catch ( Exception e )
                {
                    .log.error("Exception thrown from request handler: {} @ {}:{}",
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

/*******************************************************************************

    Static module logger

*******************************************************************************/

private Logger log;
static this ( )
{
    log = Log.lookup("swarm.node.simplified.NeoConnectionHandler");
}
