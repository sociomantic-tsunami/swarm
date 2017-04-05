/*******************************************************************************

    Fiber-based client socket connection holding request handler instances

    copyright:      Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.connection.RequestConnection;



/*******************************************************************************

    Imports

*******************************************************************************/

import swarm.Const;

import swarm.common.connection.CommandMixins;

import swarm.client.request.model.IRequest;

import swarm.client.request.params.IRequestParams;

import swarm.client.request.notifier.IRequestNotification;

import swarm.client.connection.model.INodeConnectionPool;
import swarm.client.connection.model.INodeConnectionPoolInfo;

import swarm.client.ClientExceptions;

import swarm.protocol.FiberSelectReader;
import swarm.protocol.FiberSelectWriter;

import ocean.core.Enum;

import ocean.io.select.client.FiberSelectEvent;

import ocean.io.select.fiber.SelectFiber;

import ocean.io.select.client.model.ISelectClient;

import ocean.io.select.EpollSelectDispatcher;

import ocean.io.compress.lzo.LzoChunkCompressor;

debug ( SwarmClient ) import ocean.io.Stdout;

import swarm.client.connection.FiberSocketConnection;

import ocean.transition;
import ocean.util.log.Log;



/*******************************************************************************

    Static module logger

*******************************************************************************/

static private Logger log;
static this ( )
{
    log = Log.lookup("swarm.client.connection.RequestConnection");
}


/*******************************************************************************

    Request / connection handler base class template.

    An object pool of these connection handlers is contained in the
    NodeConnectionPools which are instantiated inside the NodeRegistry.

*******************************************************************************/

public abstract class IRequestConnection :
    IAdvancedSelectClient.IFinalizer,
    IAdvancedSelectClient.IErrorReporter,
    IAdvancedSelectClient.ITimeoutReporter,
    FiberSocketConnection.IDisconnectionHandler
{
    /***************************************************************************

        Local alias type redefinitions

    ***************************************************************************/

    public alias .EpollSelectDispatcher EpollSelectDispatcher;

    public alias .LzoChunkCompressor LzoChunkCompressor;

    public alias .INodeConnectionPoolInfo INodeConnectionPoolInfo;

    protected alias .IRequestParams IRequestParams;


    /***************************************************************************

        Index allowing this object to be stored in an object pool

     **************************************************************************/

    public size_t object_pool_index;


    /**************************************************************************

        This alias for chainable methods

     **************************************************************************/

    private alias typeof(this) This;


    /***************************************************************************

        FiberSocketConnection subclass with its own timeout reporter. This is
        required because when connect() times out, the node connection should
        not be closed like on a read()/write() timeout.

    ***************************************************************************/

    private class TimeoutFiberSocketConnection : FiberSocketConnection
    {
        /***********************************************************************

            connect() timeout reporter class.

        ***********************************************************************/

        class TimeoutReporter : IAdvancedSelectClient.ITimeoutReporter
        {
            /*******************************************************************

                Called on connect() timeout.

            *******************************************************************/

            public void timeout ( )
            {
                this.outer.had_timeout = true;
                this.outer.outer.timeout();
            }
        }

        /***********************************************************************

            true if the last connect() call timed out.

        ***********************************************************************/

        public bool had_timeout;

        /***********************************************************************

            timeout_reporter instance for the disposer.

        ***********************************************************************/

        private Object timeout_reporter;

        /***********************************************************************

            Constructor.

            Params:
                fiber = SelectFiber instance to use

        ***********************************************************************/

        public this ( SelectFiber fiber )
        {
            super(fiber, this.outer);

            auto timeout_reporter = this.new TimeoutReporter;

            super.timeout_reporter = timeout_reporter;
            this.timeout_reporter = timeout_reporter;

            this.error_reporter = this.outer;
            this.finalizer = this.outer;
        }


        version (D_Version2) {}
        else
        {
            /*******************************************************************

                Disposer

            *******************************************************************/

            protected override void dispose ( )
            {
                super.dispose();
                delete this.timeout_reporter;
            }
        }

        /***********************************************************************

            Connects to the node.

            Params:
                address = node IP address
                port    = node listening TCP port

            Returns:
                ConnectionStatus.Connected when a new connection was
                established or ConnectionStatus.Already when a connection
                already existed.

            Throws:
                - SocketError on socket or I/O error,
                - SelectFiber.KilledException when a timeout or an error event
                  was reported for the socket.

        ***********************************************************************/

        override public ConnectionStatus connect ( cstring address, ushort port,
            bool force = false )
        {
            // to override method all arguments must be present however in
            // context of this class only `false` value is expected. It violates
            // substitution principle but renaming methods over such minor
            // issue is not worth the trouble
            assert (!force);
            this.had_timeout = false;
            return super.connect(address, port);
        }
    }


    /***************************************************************************

        Information interface to the connection pool managing this request.

    ***************************************************************************/

    protected INodeConnectionPool conn_pool;


    /***************************************************************************

        Reader/Writer instances, shared by all Request instances

    ***************************************************************************/

    protected FiberSelectWriter writer;
    protected FiberSelectReader reader;
    private   TimeoutFiberSocketConnection socket;


    /***************************************************************************

        SelectEvent instance, shared by all Request instances

    ***************************************************************************/

    protected FiberSelectEvent event;


    /***************************************************************************

        Fiber to handle a series of one or more requests.

    ***************************************************************************/

    protected SelectFiber fiber;


    /***************************************************************************

        Status code received from node. Reset to an undefined code before
        handling each request.

    ***************************************************************************/

    protected IStatusCodes.Value status;


    /***************************************************************************

        Parameters of request currently being handled.

    ***************************************************************************/

    protected IRequestParams params;


    /***************************************************************************

        Exception passed which the this.exception member (above) is set to when
        a timeout occurs while handling a request.

    ***************************************************************************/

    private TimedOutException timeout_exception;


    /***************************************************************************

        Exception passed which the this.exception member (above) is set to when
        a timeout occurs while a socket connection is being established.

    ***************************************************************************/

    private ConnectionTimedOutException connection_timeout_exception;


    /***************************************************************************

        Exception caught while handling the current request.

    ***************************************************************************/

    protected Exception exception;


    /***************************************************************************

        Fiber activity -- determines what the internal fiber will do when
        started.

    ***************************************************************************/

    private enum FiberMode
    {
        HandleRequest,
        EstablishConnection
    }

    private FiberMode mode;


    /***************************************************************************

        Constructor

        Params:
            epoll = selector dispatcher instance to register the socket and I/O
                events
            conn_pool = interface to an instance of NodeConnectionPool which
                handles assigning new requests to this connection, and recycling
                it when finished
            params = request params instance (passed from the outside as this
                base class does not know which IRequestParams derived class is
                needed)
            fiber_stack_size = size of connection fiber's stack (in bytes)

    ***************************************************************************/

    public this ( EpollSelectDispatcher epoll, INodeConnectionPool conn_pool,
        IRequestParams params, size_t fiber_stack_size )
    {
        assert(conn_pool !is null, typeof(this).stringof ~ ".ctor: connection pool interface must be non-null");
        assert(params !is null, typeof(this).stringof ~ ".ctor: request params instance must be non-null");

        this.conn_pool = conn_pool;

        this.timeout_exception = new TimedOutException;
        this.connection_timeout_exception = new ConnectionTimedOutException;

        this.fiber = new SelectFiber(epoll, &this.fiberMethod, fiber_stack_size);

        this.socket = this.new TimeoutFiberSocketConnection(this.fiber);
        debug ( EpollTiming ) this.socket.connection_time_dg =
            &this.socket_connection_time;

        this.reader = new FiberSelectReader(this.socket);
        this.reader.error_reporter = this;
        this.reader.timeout_reporter = this;
        this.reader.finalizer = this;

        this.writer = new FiberSelectWriter(this.socket);
        this.writer.error_reporter = this;
        this.writer.timeout_reporter = this;
        this.writer.finalizer = this;

        this.event = new FiberSelectEvent(this.fiber);

        epoll.setExpiryRegistration(this.socket);
        epoll.setExpiryRegistration(this.reader);
        epoll.setExpiryRegistration(this.writer);

        this.params = params;
    }


    version (D_Version2) {}
    else
    {
        /***********************************************************************

            Disposer

        ***********************************************************************/

        protected override void dispose ( )
        {
            super.dispose();

            delete this.reader;
            delete this.writer;
            delete this.socket;
            delete this.event;
            delete this.fiber;
            delete this.timeout_exception;
            delete this.connection_timeout_exception;
        }
    }


    /***************************************************************************

        Starts this connection handling a new request. The request fiber is
        started (see handleRequest()).

        Params:
            params = parameters describing request to start

    ***************************************************************************/

    public void startRequest ( IRequestParams params )
    {
        this.params.copy(params);

        this.mode = FiberMode.HandleRequest;
        this.fiber.start();
    }


    /***************************************************************************

        Implements the IAdvancedSelectClient.IErrorReporter interface method.
        Called directly from the select dispatcher when an error occurs.

        Params:
            e = caught Exception that caused the error
            event = Selector event status during error

    ***************************************************************************/

    public void error ( Exception e, IAdvancedSelectClient.Event event )
    {
        debug ( SwarmClient ) Stderr.formatln("[{}:{}.{}]: Select error in client",
            this.conn_pool.address, this.conn_pool.port, this.object_pool_index);
        this.conn_pool.had_error();
        this.exception = e;
    }


    /***************************************************************************

        Implements the IAdvancedSelectClient.ITimeoutReporter interface method.
        Called directly from the select dispatcher when a timeout occurs.

        Sets the this.exception member to one of the timeout exceptions,
        depending whether the timeout occurred during an I/O operation or during
        establishing a socket connection.

    ***************************************************************************/

    public void timeout ( )
    {
        if ( this.socket.had_timeout )
        {
            debug ( SwarmClient ) Stderr.formatln("[{}:{}.{}]: Connection timeout in client",
                    this.conn_pool.address, this.conn_pool.port, this.object_pool_index);
            this.conn_pool.had_conn_timeout();
            this.exception = this.connection_timeout_exception;
        }
        else
        {
            debug ( SwarmClient ) Stderr.formatln("[{}:{}.{}]: I/O timeout in client",
                    this.conn_pool.address, this.conn_pool.port, this.object_pool_index);
            this.conn_pool.had_io_timeout();
            this.exception = this.timeout_exception;
        }
    }


    /***************************************************************************

        Implements the IAdvancedSelectClient.IFinalizer interface method. Called
        directly from the select dispatcher when a client is finalized (i.e.
        when a FiberSelectReader/Writer has finished doing its thing). This can
        happen both in cases when a connection finishes normally (i.e. when a
        request finishes and no more are pending), and in cases when a
        connection is terminated abnormally, due to an error or timeout.

        In the case when an error or timeout has occurred in a select client
        (see error() & timeout(), above) the connection fiber has already been
        killed. This method will, in certain circumstances, restart the fiber:
            * When a connection timeout occurs (as a connection is initially
              being established for the first time), the fiber is restarted if
              there are more requests pending.
            * When the handling of a request is broken due to an error or
              timeout, the fiber enters a special mode where it solely attempts
              to re-establish the connection. In this way, the connection is
              marked as busy, and will not have any further requests assigned to
              it until it is re-connected. In the case where connection takes a
              long time, this prevents a series of requests being assigned to
              this connection and all timing out.
            * When an error occurs while in the special connect-only mode, the
              fiber is restarted to try again.

        (See also the comment in handleRequest() relating to the handling of
        MessageFiber.KilledExceptions.)

    ***************************************************************************/

    public void finalize ( IAdvancedSelectClient.FinalizeStatus status )
    {
        if ( status != status.Success )
        {
            bool restart_fiber;

            try
            {
                scope ( failure )
                {
                    restart_fiber = false;
                }

                with ( FiberMode ) switch ( this.mode )
                {
                    case HandleRequest:
                        this.requestFinished(!this.socket.had_timeout);

                        if ( this.socket.had_timeout )
                        {
                            restart_fiber = this.nextRequest();
                        }
                        else
                        {
                            this.mode = FiberMode.EstablishConnection;
                            restart_fiber = true;
                            debug ( SwarmClient ) Stderr.formatln("[{}:{}.{}]: Error while handling request -- re-establishing connection",
                                this.conn_pool.address, this.conn_pool.port,
                                this.object_pool_index);
                        }
                    break;

                    case EstablishConnection:
                        debug ( SwarmClient ) Stderr.formatln("[{}:{}.{}]: Error while re-establishing connection -- retrying",
                            this.conn_pool.address, this.conn_pool.port,
                            this.object_pool_index);

                        restart_fiber = true;
                    break;

                    default:
                        assert(false);
                }

                if ( restart_fiber )
                {
                    debug ( SwarmClient ) Stderr.formatln("[{}:{}.{}]: Restarting connection fiber",
                        this.conn_pool.address, this.conn_pool.port,
                        this.object_pool_index);
                    this.fiber.start();
                }
            }
            finally if ( !restart_fiber )
            {
                debug ( SwarmClient ) Stderr.formatln("[{}:{}.{}]: Connection fiber not restarted -- recycling connection",
                    this.conn_pool.address, this.conn_pool.port,
                    this.object_pool_index);
                this.recycleConnection();
            }
        }
    }


    /***************************************************************************

        Disconnects the socket used for this request connection. This method is
        called both internally and externally.

    ***************************************************************************/

    public void disconnect ( )
    {
        this.socket.disconnect();
    }


    /***************************************************************************

        Unregisters any registered select client, and clears the reader's and
        writer's internal buffers, upon socket disconnection.

        Implements the FiberSocketConnection.IDisconnectionHandler method.

    ***************************************************************************/

    protected void onDisconnect ( )
    {
        debug ( SwarmClient ) Stderr.formatln("[{}:{}.{}]: Disconnect",
            this.conn_pool.address, this.conn_pool.port,
            this.object_pool_index);

        this.writer.reset();
        this.reader.reset();

        this.fiber.unregister();
    }


    /***************************************************************************

        Fiber method.

        Initialises and handles the current request (as defined by this.params,
        set initially by startRequest()). Once the request has finished, the
        connection pool is queried for the next request, which is begun
        immediately. If no more requests are pending, the connection is
        recycled.

        Throws:
            MessageFiber.KilledException when an error has occurred in the
            FiberSelectClient, causing the request handler fiber to be killed.

    ***************************************************************************/

    private void fiberMethod ( )
    {
        debug ( SwarmClient )
        {
            Stderr.formatln("[{}:{}.{}]: Request fiber started",
                this.conn_pool.address, this.conn_pool.port,
                this.object_pool_index);
        }

        with ( FiberMode ) switch ( this.mode )
        {
            case HandleRequest:
                this.handleRequest();
            break;

            case EstablishConnection:
                this.establishConnection();
            break;

            default:
                assert(false);
        }

        debug ( SwarmClient ) Stderr.formatln("[{}:{}.{}]: No requests pending -- recycling connection",
            this.conn_pool.address, this.conn_pool.port,
            this.object_pool_index);

        this.recycleConnection();

        debug ( SwarmClient )
        {
            Stderr.formatln("[{}:{}.{}]: Request fiber finished",
                this.conn_pool.address, this.conn_pool.port,
                this.object_pool_index);
        }
    }


    /***************************************************************************

        Establishes the connection. Once the connection has been successfully
        established, the connection pool is queried for the next request, which
        is begun immediately. If no more requests are pending, the connection is
        recycled.

        Throws:
            MessageFiber.KilledException when an error has occurred in the
            FiberSelectClient, causing the request handler fiber to be killed.

    ***************************************************************************/

    private void establishConnection ( )
    {
        debug ( SwarmClient ) Stderr.formatln("[{}:{}.{}]: Establishing connection",
            this.conn_pool.address, this.conn_pool.port,
            this.object_pool_index);

        this.handleExceptions({
            this.initConnection(0);
            debug ( SwarmClient ) Stderr.formatln("[{}:{}.{}]: Finished re-establishing connection",
                this.conn_pool.address, this.conn_pool.port,
                this.object_pool_index);
            });

        if ( this.nextRequest() )
        {
            this.mode = FiberMode.HandleRequest;
            this.handleRequest();
        }
    }


    /***************************************************************************

        Delegate called by IFiberSocketConnection after a socket connection is
        successfully established. Logs the connection time.

        Params:
            microsec = connection time in microseconds

    ***************************************************************************/

    debug ( EpollTiming ) private void socket_connection_time ( ulong microsec )
    {
        log.trace("Socket connection {}:{} took {}µs",
            this.socket.address, this.socket.port, microsec);
    }


    /***************************************************************************

        Initialises and handles the current request (as defined by this.params,
        set initially by startRequest()). Once the request has finished, the
        connection pool is queried for the next request, which is begun
        immediately. If no more requests are pending, the connection is
        recycled.

        Throws:
            MessageFiber.KilledException when an error has occurred in the
            FiberSelectClient, causing the request handler fiber to be killed.

    ***************************************************************************/

    private void handleRequest ( )
    {
        do
        {
            // Prevent lingering exceptions from the previously handled request.
            this.exception = null;

            debug ( SwarmClient ) Stderr.formatln("[{}:{}.{}]: Start request",
                this.conn_pool.address, this.conn_pool.port,
                this.object_pool_index);

            this.requestStarted_();

            this.handleExceptions({
                this.initConnection(this.params.timeout_ms * 1_000);

                this.doRequest();
                });

            // this.exception can be set in handleExceptions(), above
            auto disconnect = this.exception !is null;
            this.requestFinished(disconnect);
        }
        while ( this.nextRequest() );
    }


    /***************************************************************************

        Exception handling for fiber methods handleRequest() and
        establishConnection(), above.

        Fiber kill exceptions are rethrown.

        Other exceptions are noted by storing their reference in this.exception.

        Throws:
            MessageFiber.KilledException when an error has occurred in the
            FiberSelectClient, causing the request handler fiber to be killed.

    ***************************************************************************/

    private void handleExceptions ( void delegate ( ) dg )
    {
        try
        {
            this.exception = null;

            dg();
        }
        catch ( SelectFiber.KilledException e )
        {
            // A killed exception only happens in the case where an error
            // occurs inside the selector when the client is being handled.
            // In this case, we skip the rest of the fiber, as the error()
            // and finalize() methods will be called automatically by the
            // selector. These methods take care of calling
            // requestFinished() in this case, and will either restart the
            // fiber if another request is waiting, or will recycle the
            // connection.
            debug ( SwarmClient ) Stderr.formatln("[{}:{}.{}]: Caught fiber kill exception: {}",
                this.conn_pool.address, this.conn_pool.port,
                this.object_pool_index, getMsg(e));
            throw e;
        }
        catch ( Exception e )
        {
            debug ( SwarmClient ) Stderr.formatln("[{}:{}.{}]: Caught exception in fiber: {}",
                this.conn_pool.address, this.conn_pool.port,
                this.object_pool_index, getMsg(e));
            this.exception = e;
        }
    }


    /***************************************************************************

        Called at the start of the fiber request handling loop (in
        handleRequest(), above). Resets the status code and calls the user
        notifier with the notification of the request having started. Also calls
        the requestStarted__() method. The base implementation of this method
        does nothing, but derived classes may override to add special behaviour
        at this point, immediately before the handling of a request begins.

    ***************************************************************************/

    private void requestStarted_ ( )
    {
        this.status = IStatusCodes.E.Undefined;

        this.notify(IRequestNotification.Type.Started);

        this.requestStarted__();
    }

    protected void requestStarted__ ( )
    {
    }


    /***************************************************************************

        Ensures that the socket to the node is connected. Called from within the
        fiber method (handleRequest(), above).

        Also sets up the I/O timeouts for the socket, reader and writer.

        Throws:
            IOException if socket connection cannot be opened

    ***************************************************************************/

    private void initConnection ( uint timeout_us )
    {
        debug ( SwarmClient )
        {
            Stderr.formatln("[{}:{}.{}]: initConnection",
                           this.conn_pool.address, this.conn_pool.port,
                           this.object_pool_index);

            scope (failure) Stderr.formatln("[{}:{}.{}]: initConnection failed",
                this.conn_pool.address, this.conn_pool.port,
                this.object_pool_index);
        }

        // Setup I/O timeouts
        this.socket.timeout_us = timeout_us;
        this.reader.timeout_us = timeout_us;
        this.writer.timeout_us = timeout_us;

        // Connect to socket if not already connected
        auto conn_status = this.socket.connect(
            this.conn_pool.address, this.conn_pool.port);
    }


    /***************************************************************************

        Sets up and handles a request. Called from within the fiber method
        (handleRequest(), above).

    ***************************************************************************/

    protected abstract void doRequest ( );


    /***************************************************************************

        Called when handling of a request is finished (either due to error or
        success).

            1. Calls the request notifier with type = Finished.
            2. Optionally disconnects the socket, if requested.
            3. Calls the requestFinished_() method, which in the base class
               implementation does nothing. Derived classes may implement
               special request finished behaviour here.

        Params:
            disconnect = if true, the socket will be disconnected

    ***************************************************************************/

    private void requestFinished ( bool disconnect )
    {
        debug ( SwarmClient ) Stderr.formatln("[{}:{}.{}]: Request {} finished",
            this.conn_pool.address, this.conn_pool.port,
            this.object_pool_index, this.params.command);

        this.notify(IRequestNotification.Type.Finished);

        this.requestFinished_();

        if ( disconnect )
        {
            debug ( SwarmClient ) Stderr.formatln("[{}:{}.{}]: An exception was caught while handling the request: {}",
                this.conn_pool.address, this.conn_pool.port,
                this.object_pool_index, getMsg(this.exception));
            this.disconnect();
        }
    }

    protected void requestFinished_ ( )
    {
    }


    /***************************************************************************

        Calls the user notifier for the current request.

        Params:
            notification = notification code to send

    ***************************************************************************/

    private void notify ( IRequestNotification.Type notification )
    {
        this.params.notify(this.conn_pool.address,
            this.conn_pool.port, this.exception, this.status, notification);
    }


    /***************************************************************************

        Assigns the next request if another request is ready for handling.

        Returns:
            true if another request was available from the connection pool,
            ready for handling and has been assigned or false otherwise.

    ***************************************************************************/

    private bool nextRequest ( )
    {
        this.nextRequest_();
        return this.conn_pool.nextRequest(this.params);
    }

    protected void nextRequest_ ( )
    {
    }


    /***************************************************************************

        Called when the current request has finished and there are no requests
        in the queue waiting to be processed.

        Unregisters any select clients used by the request fiber (so as to leave
        epoll in a clean state, and not leave  clients hanging around), and
        recycles this connection into the pool held in NodeConnectionPool.

    ***************************************************************************/

    private void recycleConnection ( )
    {
        this.mode = FiberMode.HandleRequest;
        this.fiber.unregister();
        this.conn_pool.recycleConnection(this);
    }
}



/*******************************************************************************

    Request / connection handler base class template.

    A set of abstract methods are mixed into the class, one per command in the
    Commands tuple. The methods are name "handle" ~ Command.name. In this way,
    one handler method is required to be implemented in a deriving class per
    command which the client is expected to be able to handle.

    Template params:
        Commands = tuple of types defining a mapping between strings (command
            names) and values (command codes). Each member of the tuple is
            expected to have members called 'value', which should be an integer,
            and 'name', which should be a string

*******************************************************************************/

public abstract class RequestConnectionTemplate ( Commands : IEnum )
    : IRequestConnection
{
    /***************************************************************************

        Constructor

        Params:
            epoll = selector dispatcher instance to register the socket and I/O
                events
            conn_pool = interface to an instance of NodeConnectionPool which
                handles assigning new requests to this connection, and recycling
                it when finished
            conn_pool_info = information interface to an instance of
                NodeConnectionPool
            params = request params instance (passed from the outside as this
                base class does not know which IRequestParams derived class is
                needed)
            fiber_stack_size = size of connection fiber's stack (in bytes)

    ***************************************************************************/

    public this ( EpollSelectDispatcher epoll,  INodeConnectionPool conn_pool,
        IRequestParams params, size_t fiber_stack_size )
    {
        super(epoll, conn_pool, params, fiber_stack_size);
    }


    /***************************************************************************

        Sets up and handles a request. Called from within the fiber method
        (handleRequest(), in the super class).

    ***************************************************************************/

    override protected void doRequest ( )
    {
        debug ( SwarmClient )
        {
            auto cmd_desc = this.params.command in Commands();
            Stderr.formatln("[{}:{}.{}]: Starting {} request handler",
                this.conn_pool.address, this.conn_pool.port,
                this.object_pool_index, cmd_desc ? *cmd_desc : "Invalid");
        }

        switch ( this.params.command )
        {
            // TODO: handling of the None case could be done in here, not in
            // derived classes -- the CommandMethods mixin would need to be
            // altered to exclude it
            mixin(CommandCases!(Commands));

            default:
                assert(false, "Invalid command code");
        }
    }


    /***************************************************************************

        Mix-in protected abstract methods to handle individual commands.

    ***************************************************************************/

    mixin(CommandMethods!(Commands));


    /***************************************************************************

        Command handler method template.

        Template params:
            Handler = type of request handler
            Resources = type of resource acquirer passed to the request

        Params:
            resources = resource acquirer to pass to the request

    ***************************************************************************/

    protected void handleCommand ( Handler : IRequest, Resources ) ( Resources resources )
    {
        scope handler = new Handler(this.reader, this.writer, resources);
        handler.handle(this.params);

        this.status = handler.status;
    }
}
