/*******************************************************************************

    Fiber-based node connection handler base class

    The node connection handler class is designed to be managed by an instance
    of SelectListener, which waits keeps a pool of connection handlers, listens
    for incoming connections, then assigns a new connection to a connection
    handler in the pool.

    The connection handler base class handles reading the command code from the
    client, checking whether it is a valid command, then selecting from a set of
    request handler objects and assigning the request to the appropriate
    handler. Once a command has finished processing, the connection handler
    tries to read the next command from the client.

    copyright:      Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.node.connection.ConnectionHandler;



/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.transition;

import swarm.Const;

import swarm.common.connection.CommandMixins;

import swarm.node.model.INodeInfo;
import swarm.node.model.ISwarmConnectionHandlerInfo;

import swarm.node.request.model.IRequest;

import ocean.util.container.pool.model.IResettable;

import ocean.core.SmartEnum;

import ocean.io.compress.lzo.LzoChunkCompressor;

import ocean.io.select.EpollSelectDispatcher;

import ocean.net.server.connection.IFiberConnectionHandler;

import ocean.io.select.client.model.ISelectClient;

import ocean.io.select.protocol.fiber.model.IFiberSelectProtocol;

import ocean.io.select.protocol.generic.ErrnoIOException : SocketError;

import swarm.protocol.FiberSelectWriter;
import swarm.protocol.FiberSelectReader;

import ocean.io.select.client.FiberSelectEvent;

import ocean.core.MessageFiber;

import ocean.core.Traits : FieldName;

import ocean.core.Traits : ctfe_i2a;

import ocean.io.model.IConduit: ISelectable;

import ocean.sys.socket.AddressIPSocket;

import IPSocket = ocean.sys.socket.IPSocket;

import core.sys.posix.netinet.in_: SOL_SOCKET, IPPROTO_TCP, SO_KEEPALIVE;

import ocean.util.log.Log;

import core.memory;

debug ( ConnectionHandler ) import ocean.io.Stdout;

import ocean.core.Traits : isArrayType;



/*******************************************************************************

    Static module logger

*******************************************************************************/

private Logger log;
static this ( )
{
    log = Log.lookup("swarm.node.connection.ConnectionHandler");
}



/*******************************************************************************

    Node connection handler setup class. Passed to the node connection handler
    constructor.

*******************************************************************************/

public class ConnectionSetupParams
{
    /***************************************************************************

        Epoll select dispatcher.

    ***************************************************************************/

    public EpollSelectDispatcher epoll;


    /***************************************************************************

        Error delegate.

    ***************************************************************************/

    public alias ISwarmConnectionHandler.ErrorDg ErrorDg;

    public ErrorDg error_dg;


    /***************************************************************************

        Information interface to the node owning this connection.

    ***************************************************************************/

    public INodeInfo node_info;
}



/*******************************************************************************

    Connection handler base class template.

    An object pool of these connection handlers is contained in the
    SelectListener which is instantiated inside the node.

    A set of abstract methods are mixed into the class, one per command in the
    Commands tuple. The methods are name "handle" ~ Command.name. In this way,
    one handler method is required to be implemented in a deriving class per
    command which the node is expected to be able to handle.

    Template params:
        Commands = tuple of types defining a mapping between strings (command
            names) and values (command codes). Each member of the tuple is
            expected to have members called 'value', which should be an integer,
            and 'name', which should be a string

*******************************************************************************/

public abstract class ConnectionHandlerTemplate ( Commands : ICommandCodes )
    : ISwarmConnectionHandler
{
    import ocean.time.StopWatch;

    /***************************************************************************

        Reuseable exception thrown when the command code read from the client
        is not supported (i.e. does not have a corresponding entry in
        this.requests).

    ***************************************************************************/

    private Exception invalid_command_exception;


    /***************************************************************************

        Buffer used for formatting the description of the current command.

    ***************************************************************************/

    protected mstring cmd_description;


    /***************************************************************************

        Constructor.

        Params:
            finalize_dg = user-specified finalizer, called when the connection
                is shut down
            setup = struct containing everything needed to set up a connection

    ***************************************************************************/

    public this ( FinalizeDg finalize_dg, ConnectionSetupParams setup )
    {
        super(finalize_dg, setup);

        this.invalid_command_exception = new Exception("Invalid command");
    }


    /***************************************************************************

        Called by IFiberConnectionHandler when a new connection is established
        by a client.

        Reads and handles the command sent by the client. If the command code is
        invalid then the connection must be killed in order to avoid reading in
        any subsequent data which the client may have sent and which will almost
        certainly be junk. This is achieved by the exception which is thrown in
        handleInvalidCommand(), below, and which is caught by the
        IFiberConnectionHandler.

    ***************************************************************************/

    override protected void handleCommand ( )
    {
        switch ( this.cmd )
        {
            mixin(CommandCases!(Commands));

            default:
                this.handleInvalidCommand();
        }
    }


     /***************************************************************************

        Enum defining the different stats tracking modes of `handleRequest()`.

    ***************************************************************************/

    protected enum RequestStatsTracking
    {
        None,   /// No stats tracking
        Count,  /// Simple stats tracking (count of handled, active, max active)
        TimeAndCount /// Counted stats (as per Count) plus request timing stats
    }


    /***************************************************************************

        Calls the handle() method of the specified request and, in debug builds,
        measures the change in allocated memory between the beginning and the
        ending of the request. Increases in allocated memory are logged.

        At exit (after finished handling the request), the size of all buffers
        acquired from the shared resources pool during the request are checked.
        If any exceed 64K, a warning is logged.

        Template params:
            Resources = type of struct defining the types and names of resources
                which a request can acquire from the shared pools
            Acquired = type of class with getters for the resources acquired by
                a request. Assumed to be generated by instantiating the
                SharedResources_T template (see
                swarm.common.connection.ISharedResources) with Resources.
            stats = request stats tracking mode (see enum)

        Params:
            request = request handler to run
            acquired = resources acquired while handling the request
            rq_name = name of request for stats tracking (default to null)

    ***************************************************************************/

    protected void handleRequest ( Resources, Acquired,
        RequestStatsTracking stats = RequestStatsTracking.None )
        ( IRequest request, Acquired acquired, cstring rq_name = "" )
    {
        debug
        {
            const float Mb = 1024 * 1024;
            size_t used1, free1;
            GC.usage(used1, free1);

            scope ( exit )
            {
                size_t used2, free2;
                GC.usage(used2, free2);

                if ( used2 > used1 )
                {
                    log.info("Memory usage increased while handling command {} "
                        "(+{} bytes)", request.description(this.cmd_description),
                        used2 - used1);
                }
            }
        }

        scope ( exit )
        {
            // Log a warning if the length of any buffers acquired from the pool
            // of shared resources while handling this command exceed a sanity
            // limit afterwards.
            const warn_limit = 1024 * 64; // anything > 64K will be logged

            foreach ( i, F; typeof(Resources.tupleof) )
            {
                static if ( isArrayType!(F) )
                {
                    // FIXME_IN_D2: can't use `const` inside static foreach
                    // while it is converted in `static immutable`
                    mixin("auto buffer = acquired."
                        ~ FieldName!(i, Resources) ~ ";");
                    if ( buffer.length > warn_limit )
                    {
                        log.warn("Request resource '{}' grew to {} bytes while "
                            "handling {}", FieldName!(i, Resources), buffer.length,
                            request.description(this.cmd_description));
                    }
                }
            }
        }

        static if ( stats == RequestStatsTracking.Count )
        {
            assert(rq_name);
            this.setup.node_info.request_stats.started(rq_name);
            scope ( exit ) this.setup.node_info.request_stats.finished(rq_name);
        }
        else static if ( stats == RequestStatsTracking.TimeAndCount )
        {
            assert(rq_name);

            StopWatch timer;
            timer.start();

            this.setup.node_info.request_stats.started(rq_name);
            scope ( exit ) this.setup.node_info.request_stats.finished(rq_name,
                timer.microsec);
        }

        request.handle();
    }


    /***************************************************************************

        Mix-in protected abstract methods to handle individual commands.

    ***************************************************************************/

    mixin(CommandMethods!(Commands));


    /***************************************************************************

        Called when an invalid command code is read from the connection. As the
        read buffer may now contain unknown data, the connection is simply
        broken by throwing an exception. The protected handleInvalidCommand_()
        is also called, allowing derived classes to add extra behaviour at this
        stage.

    ***************************************************************************/

    final protected void handleInvalidCommand ( )
    {
        this.handleInvalidCommand_();
        throw this.invalid_command_exception;
    }

    protected void handleInvalidCommand_ ( )
    {
    }
}



/*******************************************************************************

    Connection handler abstract base class.

*******************************************************************************/

abstract public class ISwarmConnectionHandler : IFiberConnectionHandlerBase,
    Resettable, ISwarmConnectionHandlerInfo
{
    /***************************************************************************

        Extends FiberSelectReader by counting the number of bytes received.

    ***************************************************************************/

    private class Reader : FiberSelectReader
    {
        /***********************************************************************

            Constructor.

            error_e and warning_e may be the same object if distinguishing
            between error and warning is not required.

            Params:
                input       = input device
                fiber       = input reading fiber
                warning_e   = exception to throw on end-of-flow condition or if
                    the remote hung up
                error_e     = exception to throw on I/O error
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
                socket      = socket to read from
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
                this.outer.setup.node_info.receivedBytes(bytes_received);
                this.outer.had_io_ = true;
            }

            return super.transmit(events);
        }
    }

    /***************************************************************************

        Extends FiberSelectWriter by counting the number of bytes sent.

    ***************************************************************************/

    private class Writer : FiberSelectWriter
    {
        /***********************************************************************

            Constructor

            Params:
                output = output device
                fiber  = output writing fiber
                warning_e   = exception to throw on end-of-flow condition or if
                    the remote hung up
                error_e     = exception to throw on I/O error
                size   = buffer size

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
                socket      = socket to write to

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
                this.outer.setup.node_info.sentBytes(bytes_sent);
                this.outer.had_io_ = true;
            }

            return super.transmit(events);
        }
    }

    /***************************************************************************

        Reader and Writer used for asynchronous protocol i/o.

    ***************************************************************************/

    protected Reader reader;
    protected Writer writer;


    /***************************************************************************

        Flag set when an I/O event occurs on this connection (in the transmit()
        methods of the Reader and Writer, above). Reset by the informational
        method had_io().

    ***************************************************************************/

    private bool had_io_;


    /***************************************************************************

        Struct containing all the values passed to the constructor.

    ***************************************************************************/

    protected ConnectionSetupParams setup;


    /***************************************************************************

        Command code read from client.

    ***************************************************************************/

    protected ICommandCodes.Value cmd;


    /***************************************************************************

        Instance id number in debug builds.

    ***************************************************************************/

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
            setup = struct containing everything needed to set up a connection

    ***************************************************************************/

    public this ( FinalizeDg finalize_dg, ConnectionSetupParams setup )
    {
        debug this.connection_id = connection_count++;

        this.setup = setup;

        auto socket = new AddressIPSocket!();
        super(this.setup.epoll, socket, finalize_dg, &this.error);

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
        assert( socket_ip !is null );
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
        assert( socket_ip !is null );
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
        this.socket.setsockoptVal(IPPROTO_TCP, IPSocket.TcpOptions.TCP_KEEPIDLE, 5);

        // Maximum number of keepalive probes before the connection is declared
        // dead and dropped.
        this.socket.setsockoptVal(IPPROTO_TCP, IPSocket.TcpOptions.TCP_KEEPCNT, 3);

        // Time in seconds between keepalive probes.
        this.socket.setsockoptVal(IPPROTO_TCP, IPSocket.TcpOptions.TCP_KEEPINTVL, 3);
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

        if ( this.setup.error_dg )
        {
            this.setup.error_dg(e, event, conn);
        }
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

unittest
{
    static class TestCommands : ICommandCodes
    {
        import ocean.core.Enum;

        mixin EnumBase!([
            "Put"[]:    1,
            "Get":      2,
            "Remove":   3
        ]);
    }

    alias ConnectionHandlerTemplate!(TestCommands) Dummy;
}
