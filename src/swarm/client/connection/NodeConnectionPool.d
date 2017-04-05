/*******************************************************************************

    Pool of client socket connections holding request handler instances

    copyright:      Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.connection.NodeConnectionPool;



/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.transition;
import swarm.Const;

import swarm.client.connection.RequestConnection;

import swarm.client.model.ClientSettings;

import swarm.client.connection.model.INodeConnectionPool;
import swarm.client.connection.model.INodeConnectionPoolErrorReporter;

import swarm.client.connection.RequestOverflow;

import swarm.client.request.model.IRequest;

import swarm.client.request.params.IRequestParams;

import swarm.client.request.notifier.IRequestNotification;

import swarm.client.ClientExceptions;

import ocean.core.TypeConvert : castFrom;

import ocean.util.container.pool.ObjectPool;

import ocean.io.select.client.model.ISelectClient;

import ocean.io.select.EpollSelectDispatcher;

//version = FixedQueue;

version ( FixedQueued )
{
    import ocean.util.container.queue.FixedRingQueue;
}
else
{
    import ocean.util.container.queue.FlexibleRingQueue;
}

debug ( SwarmClient ) import ocean.io.Stdout;



/*******************************************************************************

    Client connection pool non-template base class. Derived from ObjectPool.

*******************************************************************************/

public abstract class NodeConnectionPool
    : ObjectPool!(IRequestConnection), INodeConnectionPool
{
    /***************************************************************************

        Local alias type redefinitions

    ***************************************************************************/

    protected alias .EpollSelectDispatcher EpollSelectDispatcher;

    protected alias .IRequestOverflow IRequestOverflow;

    protected alias .IRequestParams IRequestParams;

    protected alias .IRequestConnection IRequestConnection;

    protected alias .INodeConnectionPoolErrorReporter INodeConnectionPoolErrorReporter;

    protected alias .ClientSettings ClientSettings;


    /***************************************************************************

        Instance identifier (debugging only).

    ***************************************************************************/

    debug
    {
        private static uint ID = 0;

        protected uint id;
    }


    /***************************************************************************

        This alias for chainable methods

    ***************************************************************************/

    private alias typeof(this) This;


    /***************************************************************************

        Node item struct to store the address and port node to which the
        connection in this pool are connected.

    ***************************************************************************/

    private NodeItem node_item;


    /***************************************************************************

        Epoll dispatcher used by this connection pool. Passed as a reference to
        the constructor.

    ***************************************************************************/

    protected EpollSelectDispatcher epoll;


    /***************************************************************************

        Error reporter

    ***************************************************************************/

    private INodeConnectionPoolErrorReporter error_reporter;


    /***************************************************************************

        Size (in bytes) of connections' fiber stacks

    ***************************************************************************/

    protected Const!(size_t) fiber_stack_size;


    /***************************************************************************

        Queue of requests awaiting processing

    ***************************************************************************/

    version ( FixedQueued )
    {
        private FixedByteRingQueue request_queue;
    }
    else
    {
        private FlexibleByteRingQueue request_queue;
    }


    /***************************************************************************

        Counters for errors and timeouts in connections in the pool.

    ***************************************************************************/

    private ulong error_count_;
    private ulong io_timeout_count_;
    private ulong conn_timeout_count_;


    /***************************************************************************

        Toggles popping of requests from the request queue.

    ***************************************************************************/

    private bool suspended_;


    /***************************************************************************

        Request overflow handler -- decides what to do with a newly assigned
        request when the request queue is full.

    ***************************************************************************/

    private IRequestOverflow request_overflow;


    /***************************************************************************

        Exception thrown when a request is added but the request queue is full.

    ***************************************************************************/

    protected RequestQueueFullException request_queue_full_exception;


    /***************************************************************************

        Constructor

        Params:
            settings = client settings instance
            epoll = selector dispatcher instance to register the socket and I/O
                events
            address = node address
            port = node service port
            request_overflow = overflow handler for requests which don't fit in
                the request queue
            error_reporter = error reporter instance to notify on error or
                timeout

    ***************************************************************************/

    public this ( ClientSettings settings, EpollSelectDispatcher epoll,
        mstring address, ushort port, IRequestOverflow request_overflow,
        INodeConnectionPoolErrorReporter error_reporter )
    {
        assert(request_overflow, typeof(this).stringof ~ ".ctor: request overflow instance is null");

        this.epoll = epoll;
        this.fiber_stack_size = settings.fiber_stack_size;

        this.node_item = NodeItem(address, port);

        this.request_queue_full_exception = new RequestQueueFullException;

        super.setLimit(castFrom!(size_t).to!(uint)(settings.conn_limit));
        super.fill(settings.conn_limit, this.newConnection());

        debug
        {
            this.id = ++this.ID;
        }

        version ( FixedQueued )
        {
            auto params = this.newRequestParams();
            this.request_queue = new FixedByteRingQueue(params.serialized_length,
                queue_size);
        }
        else
        {
            this.request_queue = new FlexibleByteRingQueue(settings.queue_size);
        }

        this.request_overflow = request_overflow;
        this.error_reporter = error_reporter;
    }


    /***************************************************************************

        Implements the INodeConnectionPoolInfo method.

        Returns:
            the address of the node

    ***************************************************************************/

    override public mstring address ( )
    {
        return this.node_item.Address;
    }


    /***************************************************************************

        Implements the INodeConnectionPoolInfo method.

        Returns:
            the service port of the node

    ***************************************************************************/

    public ushort port ( )
    {
        return this.node_item.Port;
    }


    /***************************************************************************

        opCmp function, compares this instance against another based on the
        node item member (node address/port).

        Params:
            obj = reference to object to be compared

        Returns:
            > 0 if this > obj
            < 0 if obj < this
            0 if obj == this

    ***************************************************************************/

    public mixin(genOpCmp(`
    {
        auto other = cast(typeof(this)) rhs;
        assert(other);
        return this.node_item.opCmp(other.node_item);
    }
    `));


    /**************************************************************************

        Returns the total number of node connections in the pool, that is, the
        maximum number of connections to this node that have ever been busy
        simultaneously.

        This wrapper is required to implement INodeConnectionPoolInfo.

        Returns:
            the total number of connections in the pool.

     **************************************************************************/

    override public size_t length ( ) { return super.length(); }


    /**************************************************************************

        Returns the number of idle node connections. The socket connection of
        each of these connections may or may not be open currently.

        This wrapper is required to implement INodeConnectionPoolInfo.

        Returns:
            the number of idle node connections.

     **************************************************************************/

    override public size_t num_idle ( ) { return super.num_idle(); }


    /**************************************************************************

        Returns the number of busy node connections.

        This wrapper is required to implement INodeConnectionPoolInfo.

        Returns:
            the number of busy items in pool

     **************************************************************************/

    override public size_t num_busy ( ) { return super.num_busy(); }


    /***************************************************************************

        Implements the INodeConnectionPoolInfo method.

        Returns:
            the number of connections currently being established

        TODO

    ***************************************************************************/

//    public uint num_connecting ( )
//    {
//        return 0;
//    }


    /***************************************************************************

        Implements the INodeConnectionPoolInfo method.

        Returns:
            the number of requests in the request queue

    ***************************************************************************/

    public size_t queued_requests ( )
    {
        return this.request_queue.length;
    }


    /***************************************************************************

        Implements the INodeConnectionPoolInfo method.

        Returns:
            the number of bytes occupied in the request queue

    ***************************************************************************/

    public size_t queued_bytes ( )
    {
        return this.request_queue.used_space;
    }


    /***************************************************************************

        Returns:
            the number of requests in the overflow queue

    ***************************************************************************/

    public size_t overflowed_requests ( )
    {
        return this.request_overflow.length(this.node_item);
    }


    /***************************************************************************

        Returns:
            the number of bytes in the overflow queue

    ***************************************************************************/

    public size_t overflowed_bytes ( )
    {
        return this.request_overflow.used_space(this.node_item);
    }


    /***************************************************************************

        Implements the INodeConnectionPool method.

        Increments the error counter.

    ***************************************************************************/

    public void had_error ( )
    {
        this.error_count_++;

        if ( this.error_reporter )
        {
            this.error_reporter.had_error(this.node_item);
        }
    }


    /***************************************************************************

        Implements the INodeConnectionPoolInfo method.

        Returns:
            the number of requests which ended due to an error, since the last
            call to resetCounters()

    ***************************************************************************/

    public ulong error_count ( )
    {
        return this.error_count_;
    }


    /***************************************************************************

        Implements the INodeConnectionPool method.

        Increments the I/O timeout counter.

    ***************************************************************************/

    public void had_io_timeout ( )
    {
        this.io_timeout_count_++;

        if ( this.error_reporter )
        {
            this.error_reporter.had_io_timeout(this.node_item);
        }
    }


    /***************************************************************************

        Implements the INodeConnectionPoolInfo method.

        Returns:
            the number of requests which ended due to an I/O timeout, since the
            last call to resetCounters()

    ***************************************************************************/

    public ulong io_timeout_count ( )
    {
        return this.io_timeout_count_;
    }


    /***************************************************************************

        Implements the INodeConnectionPool method.

        Increments the connection timeout counter.

    ***************************************************************************/

    public void had_conn_timeout ( )
    {
        this.conn_timeout_count_++;

        if ( this.error_reporter )
        {
            this.error_reporter.had_conn_timeout(this.node_item);
        }
    }


    /***************************************************************************

        Implements the INodeConnectionPoolInfo method.

        Returns:
            the number of requests which ended due to a connection timeout,
            since the last call to resetCounters()

    ***************************************************************************/

    public ulong conn_timeout_count ( )
    {
        return this.conn_timeout_count_;
    }


    /***************************************************************************

        Implements the INodeConnectionPoolInfo method.

        Resets the internal counters of errors and timeouts.

    ***************************************************************************/

    public void resetCounters ( )
    {
        this.error_count_ = 0;
        this.io_timeout_count_ = 0;
        this.conn_timeout_count_ = 0;
    }


    /**************************************************************************

        Returns:
            whether the request queue for this connection pool is currently
            suspended (via the SuspendNode client command)

     **************************************************************************/

    public bool suspended ( ) { return this.suspended_; }


    /***************************************************************************

        Adds a request. If currently there are connections available from the
        pool, the request is assigned to a connection, otherwise it is appended
        to the request queue.

        Params:
            params = request parameters

        Returns:
            this instance

    ***************************************************************************/

    public This assign ( IRequestParams params )
    {
        if ( this.suspended_ || super.num_idle == 0 )
        {
            this.queueRequest(params);
        }
        else
        {
            this.startRequest(params);
        }

        return this;
    }


    /***************************************************************************

        Implements the INodeConnectionPool method.

        Called when a connection has finished handling a request. If there are
        requests in queue, the next request is popped from queue and assigned to
        the connection that has just become idle. Otherwise the connection will
        be unregistered from the select dispatcher.

        Params:
            params = outputs request params for next request

        Returns:
            true if another request is available

    ***************************************************************************/

    public bool nextRequest ( IRequestParams params )
    {
        debug ( SwarmClient ) Stderr.formatln("Next request ({} queued "
            "{} overflowed{}) ----------------------------------------------------",
            this.request_queue.length, this.request_overflow.length(this.node_item),
            this.suspended_ ? " -- suspended" : "");

        if ( this.suspended_ )
        {
            return false;
        }

        bool popped = this.popFromQueue(params);
        if ( !popped && this.request_overflow.pop(this.node_item) )
        {
            debug ( SwarmClient ) Stderr.formatln("Restored request from "
                    "overflow for {}:{}. Overflow now contains {} requests.",
                    this.address, this.port,
                    this.request_overflow.length(this.node_item));

            // A second pop from the request queue is attempted, as the
            // request_overflow's pop() method, if successful, will normally
            // call assign(), which could possibly add a new request to the
            // queue. If this happens, we can pop it straight away and continue
            // processing.
            popped = this.popFromQueue(params);
        }

        return popped;
    }


    /***************************************************************************

        Suspends popping of further requests from the request queue. Active
        requests are unaffected and will continue processing.

        Multiple calls to suspend have no effect.

    ***************************************************************************/

    public void suspend ( )
    {
        debug ( SwarmClient ) Stderr.formatln("Suspending requests to {}:{}",
                this.address, this.port);
        this.suspended_ = true;
    }


    /***************************************************************************

        Resumes popping of requests from the request queue, if it has been
        suspended previously. If any requests are queued, a free connection (if
        available) is immediately assigned to process the queued requests.

        Multiple calls to resume have no effect.

    ***************************************************************************/

    public void resume ( )
    {
        debug ( SwarmClient ) Stderr.formatln("Resuming requests to {}:{}",
                this.address, this.port);
        this.suspended_ = false;

        // Start an idle connection request running
        scope params = this.newRequestParams(); // FIXME: this isn't on the stack!
        if ( this.num_idle > 0 && this.nextRequest(params) )
        {
            this.startRequest(params);
        }
    }


    /***************************************************************************

        Closes the sockets of all active connections. This will also unregister
        them from the epoll select dispatcher.

        Returns:
            this instance

    ***************************************************************************/

    public This closeActiveConnections ( )
    {
        scope iterator = super.new BusyItemsIterator;

        scope (exit) super.clear();

        return this.closeConnections_(iterator);
    }


    /***************************************************************************

        Closes the sockets of all idle connections.

        Returns:
            this instance

    ***************************************************************************/

    public This closeIdleConnections ( )
    {
        scope iterator = super.new IdleItemsIterator;

        return this.closeConnections_(iterator);
    }


    /***************************************************************************

        Closes all connections.

        Returns:
            this instance

    ***************************************************************************/

    public This closeConnections ( )
    {
        scope iterator = super.new AllItemsIterator;

        scope (exit) super.clear();

        return this.closeConnections_(iterator);
    }


    /***************************************************************************

        Implements the INodeConnectionPool method.

        Puts connection back into pool.

        Params:
            connection = RequestConnection instance to recycle

    ***************************************************************************/

    public void recycleConnection ( IRequestConnection connection )
    {
        debug ( SwarmClient ) Stderr.formatln("Recycle connection");
        super.recycle(connection);
    }


    /***************************************************************************

        Creates a new instance of the connection request handler class.

        Returns:
            new instance of type RequestConnection

    ***************************************************************************/

    protected abstract IRequestConnection newConnection ( );


    /***************************************************************************

        Returns:
            a new request params instance

    ***************************************************************************/

    protected abstract IRequestParams newRequestParams ( );


    /***************************************************************************

        Closes the connections over which iterator iterates.

        Returns:
            this instance

    ***************************************************************************/

    private This closeConnections_ ( IItemsIterator iterator )
    {
        foreach (conn; iterator)
        {
            conn.disconnect();
        }

        return this;
    }


    /***************************************************************************

        Starts a request, getting an idle connection from the pool to handle it.

        Params:
            params = request parameters

    ***************************************************************************/

    private void startRequest ( IRequestParams params )
    {
        assert(this.num_idle > 0);

        // newConnection() will never be called, as all connections have been
        // newed in the constructor by calling super.fill.
        auto conn = super.get(this.newConnection());
        assert(conn !is null, typeof(this).stringof ~
            ".startRequest: error getting idle connection from pool");

        conn.startRequest(params);
    }


    /***************************************************************************

        Pops a request from the queue. If a request is popped, it is
        deserialized into the provided IRequestParams instance.

        Params:
            params = request params instance to deserialize popped request into

        Returns:
            true if a request was popped, false if the request queue is empty

    ***************************************************************************/

    private bool popFromQueue ( IRequestParams params )
    {
        auto popped = this.request_queue.pop();
        if ( popped.length )
        {
            params.deserialize(popped);
            return true;
        }
        else
        {
            return false;
        }
    }


    /***************************************************************************

        Pushes a request into queue. If the queue is full, then the request is
        pushed into the overflow. If the overflow is full, then the notifier is
        called, and the request is aborted.

        Params:
            params = request parameters

    ***************************************************************************/

    protected void queueRequest ( IRequestParams params )
    {
        auto push_slice = this.request_queue.push(params.serialized_length);
        if ( push_slice )
        {
            params.notify(this.address, this.port, null, IStatusCodes.E.Undefined,
                IRequestNotification.Type.Queued);
            params.serialize(push_slice);
        }
        else
        {
            if ( this.request_overflow.push(params, this.node_item) )
            {
                debug ( SwarmClient ) Stderr.formatln("Overflowed request for {}:{}. "
                        "Overflow now contains {} requests.", this.address,
                        this.port, this.request_overflow.length(this.node_item));
            }
            else
            {
                this.notifyRequestQueueOverflow(params);
            }
        }
    }

    /***************************************************************************

        May be overridden by a subclass to change notification behaviour.

        Params:
            params = request parameters

    ***************************************************************************/

    protected void notifyRequestQueueOverflow ( IRequestParams params )
    {
        params.notify(this.address, this.port,
            this.request_queue_full_exception, IStatusCodes.E.Undefined,
            IRequestNotification.Type.Finished);
    }
}
