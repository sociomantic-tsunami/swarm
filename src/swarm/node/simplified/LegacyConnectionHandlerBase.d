/*******************************************************************************

    Legacy protocol node connection handler base class.

    The node connection handler class is designed to be managed by an instance
    of SelectListener, which waits keeps a pool of connection handlers, listens
    for incoming connections, then assigns a new connection to a connection
    handler in the pool.

    The connection handler base class handles the basic functionality of reading
    from and writing to the connection socket, as well as reading the command
    code from the client and dispatching it to the abstract handleCommand()
    method. Once a command has finished processing, the connection handler tries
    to read the next command from the client.

    TODO: this module is a replacement of the deprecated
    swarm.node.connection.ConnectionHandler : ISwarmConnectionHandler. The one
    difference is that this class has a simple reference to the node to which it
    belongs, rather than all node information being copied into a "connection
    setup params" object. When the deprecated module is removed, this module may
    be moved into its place.

    copyright:
        Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.node.simplified.LegacyConnectionHandlerBase;

import ocean.net.server.connection.IFiberConnectionHandler;
import ocean.util.container.pool.model.IResettable;

/// ditto
abstract public class LegacyConnectionHandlerBase : IFiberConnectionHandlerBase,
    Resettable
{
    import swarm.Const;
    import swarm.node.simplified.NodeBase;
    import swarm.node.model.INodeInfo;
    import swarm.node.simplified.NodeBase;
    import swarm.node.request.model.IRequest;
    import swarm.protocol.FiberSelectWriter;
    import swarm.protocol.FiberSelectReader;

    import ocean.transition;
    import ocean.core.MessageFiber;
    import ocean.core.SmartEnum;
    import ocean.core.Traits : isArrayType, ctfe_i2a, FieldName;
    import ocean.io.model.IConduit: ISelectable;
    import ocean.io.select.client.FiberSelectEvent;
    import ocean.io.select.client.model.ISelectClient;
    import ocean.io.select.client.model.ISelectClientInfo;
    import ocean.io.select.EpollSelectDispatcher;
    import ocean.io.select.protocol.fiber.model.IFiberSelectProtocol;
    import ocean.io.select.protocol.generic.ErrnoIOException : SocketError;
    import ocean.net.server.connection.IConnectionHandlerInfo;
    import ocean.sys.socket.AddressIPSocket;
    import IPSocket = ocean.sys.socket.IPSocket;
    debug ( ConnectionHandler ) import ocean.io.Stdout;

    import core.memory;
    import core.sys.posix.netinet.in_: SOL_SOCKET, IPPROTO_TCP, SO_KEEPALIVE;

    /// Extends FiberSelectReader by counting the number of bytes received.
    private class Reader : FiberSelectReader
    {
        /***********************************************************************

            Constructor.

            error_e and warning_e may be the same object if distinguishing
            between error and warning is not required.

            Params:
                input = input device
                fiber = input reading fiber
                warning_e = exception to throw on end-of-flow condition or if
                    the remote hung up
                error_e = exception to throw on I/O error
                buffer_size = input buffer size

        ***********************************************************************/

        public this ( IInputDevice input, SelectFiber fiber,
            IOWarning warning_e, IOError error_e,
            size_t buffer_size = this.default_buffer_size )
        {
            super(input, fiber, warning_e, error_e, buffer_size);
        }

        /***********************************************************************

            Constructor

            Params:
                socket = socket to read from
                buffer_size = input buffer size

        ***********************************************************************/

        private this ( IFiberSelectProtocol socket,
                       size_t buffer_size = this.default_buffer_size )
        {
            super(socket, buffer_size);
        }

        /***********************************************************************

            Calls the super class method and counts the number of bytes
            received on success.

            Params:
                events = (passed through to the overridden method)

            Returns:
                (passed through from the overridden method)

            Throws:
                IOException if no data were received and won't arrive later (see
                overridden method).

        ***********************************************************************/

        protected override bool transmit ( Event events )
        {
            size_t remaining_before = this.remaining_data.length;

            scope (success)
            {
                auto bytes_received = this.remaining_data.length - remaining_before;
                this.outer.node.io_stats.bytes_received += bytes_received;
                this.outer.had_io_ = true;
            }

            return super.transmit(events);
        }
    }

    /// Extends FiberSelectWriter by counting the number of bytes sent.
    private class Writer : FiberSelectWriter
    {
        /***********************************************************************

            Constructor

            Params:
                output = output device
                fiber = output writing fiber
                warning_e = exception to throw on end-of-flow condition or if
                    the remote hung up
                error_e = exception to throw on I/O error
                size = buffer size

            In:
                The buffer size must not be 0.

        ***********************************************************************/

        public this ( IOutputDevice output, SelectFiber fiber,
            IOWarning warning_e, IOError error_e,
            size_t size = default_buffer_size )
        {
            super(output, fiber, warning_e, error_e);
        }

        /***********************************************************************

            Constructor

            Params:
                socket = socket to write to

        ************************************************************************/

        private this ( IFiberSelectProtocol socket )
        {
            super(socket);
        }

        /***********************************************************************

            Calls the super class method and counts the number of bytes sent on
            on success.

            Params:
                events = (passed through to the overridden method)

            Returns:
                (passed through from the overridden method)

            Throws:
                IOException if the connection is closed or broken:
                    - IOWarning if the remote hung up,
                    - IOError (IOWarning subclass) on I/O error.
                (see overridden method).

        ***********************************************************************/

        protected override bool transmit ( Event events )
        {
            auto sent_before = this.sent;

            scope ( success )
            {
                auto bytes_sent = this.sent - sent_before;
                this.outer.node.io_stats.bytes_sent += bytes_sent;
                this.outer.had_io_ = true;
            }

            return super.transmit(events);
        }
    }

    /// Reader used for protocol I/O.
    protected Reader reader;

    /// Writer used for protocol I/O.
    protected Writer writer;

    /// Reference to the node which owns this connection.
    protected NodeBase node;

    /// Command code read from client.
    protected ICommandCodes.Value cmd;

    /// Flag set when an I/O event occurs on this connection (in the transmit()
    /// methods of the Reader and Writer, above). Reset by the informational
    /// method had_io().
    private bool had_io_;

    /// Instance id number in debug builds.
    debug
    {
        static private uint connection_count;
        private uint connection_id;
    }

    /***************************************************************************

        Constructor.

        Params:
            finalize_dg = user-specified finalizer, called when the connection
                is shut down
            node = struct containing everything needed to set up a connection

    ***************************************************************************/

    public this ( FinalizeDg finalize_dg, NodeBase node )
    {
        debug this.connection_id = connection_count++;

        this.node = node;

        super(this.node.epoll, new AddressIPSocket!(), finalize_dg, &this.error);

        auto exception = new SocketError(this.socket);
        this.reader = this.new Reader(this.socket, this.fiber,
            exception, exception);
        this.reader.error_reporter = this;

        this.writer = this.new Writer(this.reader);
        this.writer.error_reporter = this;
    }

    /***************************************************************************

        Obtains the IP address most recently passed to bind() or connect() or
        obtained by accept().

        Returns:
            the current IP address.

    ***************************************************************************/

    public cstring address ( )
    {
        auto socket_ip = cast(AddressIPSocket!()) this.socket;
        assert(socket_ip !is null);
        return socket_ip.address;
    }

    /***************************************************************************

        Obtains the port number most recently passed to bind() or connect() or
        obtained by accept().

        Returns:
            the current port number.

    ***************************************************************************/

    public ushort port ( )
    {
        auto socket_ip = cast(AddressIPSocket!()) this.socket;
        assert(socket_ip !is null);
        return socket_ip.port;
    }

    /***************************************************************************

        Accepts a pending connection from listening_socket and assigns it to the
        socket of this instance.

        The TCP keepalive feature is also activated for the socket, once it has
        been successfully accepted.

        Params:
            listening_socket = the listening server socket for which a client
                               connection is pending

    ***************************************************************************/

    override public void assign ( ISelectable listening_socket )
    {
        super.assign(listening_socket);

        // Activates TCP's keepalive feature for this socket.
        this.socket.setsockoptVal(SOL_SOCKET, SO_KEEPALIVE, true);

        // Socket idle time in seconds after which TCP will start sending
        // keepalive probes.
        this.socket.setsockoptVal(IPPROTO_TCP,
            IPSocket.TcpOptions.TCP_KEEPIDLE, 5);

        // Maximum number of keepalive probes before the connection is declared
        // dead and dropped.
        this.socket.setsockoptVal(IPPROTO_TCP,
            IPSocket.TcpOptions.TCP_KEEPCNT, 3);

        // Time in seconds between keepalive probes.
        this.socket.setsockoptVal(IPPROTO_TCP,
            IPSocket.TcpOptions.TCP_KEEPINTVL, 3);
    }

    /***************************************************************************

        Called by IFiberConnectionHandler when a new connection is established
        by a client.

        Reads the command sent by the client and calls the abstract
        handleCommand() method.

    ***************************************************************************/

    override final public void handle ( )
    {
        while ( true )
        {
            this.cmd = ICommandCodes.E.None;

            this.reader.read(this.cmd);

            this.handleCommand();
        }
    }

    /***************************************************************************

        Called by handle() when a new connection is established by a client and
        the command code sent by the client has been read into this.cmd.

    ***************************************************************************/

    abstract protected void handleCommand ( );

    /***************************************************************************

        Called when this connection is returned to the object pool stored in the
        SelectListener. This happens both in case of success or error.

        The read and write buffers are reset, to make sure the next time this
        connection handler is used, there's no junk data left over in the
        buffers.

    ***************************************************************************/

    public void reset ( )
    {
        this.reader.reset();
        this.writer.reset();
    }

    /***************************************************************************

        Returns:
            true if the connection has had an I/O event since the last time this
            method was called

    ***************************************************************************/

    public bool had_io ( )
    {
        scope ( exit ) this.had_io_ = false;
        return this.had_io_;
    }

    /***************************************************************************

        Returns:
            the code of the command currently being handled

    ***************************************************************************/

    public ICommandCodes.Value command ( )
    {
        return this.cmd;
    }

    /***************************************************************************

        Returns:
            informational interface to currently registered ISelectClient for
            this connection (may be null if no client is registered)

    ***************************************************************************/

    public ISelectClientInfo registered_client ( )
    {
        return this.fiber.registered_client;
    }

    /***************************************************************************

        Called when an error occurs while handling this connection. Calls the
        error delegate.

        Note that the read and write buffers are cleared by the reset() method,
        above, which will be called after this method.

        Params:
            exception = exception which caused the error
            event = epoll select event during which error occurred

    ***************************************************************************/

    protected void error ( Exception e, IAdvancedSelectClient.Event event,
        IConnectionHandlerInfo conn )
    {
        debug ( ConnectionHandler )
        {
            if ( this.cmd )
            {
                Stderr.formatln("[{}]: Error handling request {}: '{}'",
                super.connection_id, this.cmd, getMsg(e));
            }
            else
            {
                Stderr.formatln("[{}]: Error reading request command: '{}'",
                super.connection_id, getMsg(e));
            }
        }

        this.node.error(e, event, conn);
    }

    /***************************************************************************

        Called by the base class when an exception is caught while handling a
        connection, in order to determine if the exception was caused by an I/O
        error. (See comment for IFiberConnectionHandlerBase.handleConnection()
        method.)

        Returns:
            true if an exception was thrown due to an I/O error in either the
            reader or the writer

    ***************************************************************************/

    override protected bool io_error ( )
    {
        return this.reader.io_error || this.writer.io_error;
    }
}
