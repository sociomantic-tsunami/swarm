/*******************************************************************************

    Client Full-duplex request manager.

    Data structures:

    - There is one global RequestSet and one global ConnectionSet objects.
    - The ConnectionSet hands out shared Connection objects.
    - RequestSet creates a Request object and stores them in a map of active
      requests. Request removes itself from that map when finished. The map also
      serves as an object pool.
    - Request borrows RequestOnConn from the pool owned by RequestSet:
        - for a single-node request one RequestOnConn object,
        - for an all-nodes request <number of nodes> RequestOnConn object(s).
      Each RequestOnConn object is obtained from the pool just before starting
      the request handler fiber and returned just before the fiber terminates.

    These classes are not intended to be derived from (hence declared final).
    This is a conscious design decision to avoid big class hierarchies using
    inheritance for composition. Specialisation is supported via the opaque blob
    that is passed from outside into the Request, allowing each request type to
    associate its own, arbitrary data with a Request instance.

    Copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.client.RequestSet;

import swarm.neo.client.IRequestSet;
import swarm.neo.client.ConnectionSet;

/// ditto
public final class RequestSet: IRequestSet
{
    import swarm.neo.client.RequestOnConn;
    import swarm.neo.client.RequestOnConnSet;
    import swarm.neo.client.RequestHandlers;
    import swarm.neo.util.TreeMap;
    import ocean.transition;
    import swarm.neo.IPAddress;
    import swarm.neo.protocol.Message: RequestId;

    /***************************************************************************

        Manages a single-node or all-nodes request. Keeps track of the running
        request handler fibers and which node connection is used by the request
        handler.

    ***************************************************************************/

    public final class Request: IRequest, IRequestController
    {
        import swarm.neo.client.Connection;
        import ocean.core.SmartUnion;
        import ocean.util.serialize.contiguous.Serializer;
        import ocean.util.serialize.contiguous.Deserializer;
        import ocean.time.MicrosecondsClock;

        import ocean.transition;

        /***********************************************************************

            Iterator over the stored working data of the connections of this
            request.

        ***********************************************************************/

        private scope class RequestWorkingData : IRequestWorkingData
        {
            public override int opApply (
                int delegate ( ref Const!(void)[] working_data ) dg )
            {
                if ( this.outer.request_on_conns.is_all_nodes )
                {
                    int ret;
                    foreach ( request_on_conn; this.outer.request_on_conns.all_nodes )
                    {
                        auto working_data = request_on_conn.getWorkingData();
                        ret = dg(working_data);
                        if ( ret )
                            break;
                    }
                    return ret;
                }
                else
                {
                    auto working_data =
                        this.outer.request_on_conns.single_node.getWorkingData();
                    dg(working_data);
                    return 0;
                }
            }
        }

        /***********************************************************************

            Union of possible request handlers.

        ***********************************************************************/

        private union Handler
        {
            AllNodesHandler all_nodes;
            SingleNodeHandler single_node;
            RoundRobinHandler round_robin;
        }

        /***********************************************************************

            SmartUnion of possible request handlers.

        ***********************************************************************/

        private alias SmartUnion!(Handler) HandlerUnion;

        /***********************************************************************

            The `Active` enum of the request handler SmartUnion can be used as a
            general "what type of request is this?" enum (including a "none"
            member).

        ***********************************************************************/

        public alias HandlerUnion.Active Type;

        /***********************************************************************

            The request handler.

        ***********************************************************************/

        private HandlerUnion handler;

        /***********************************************************************

            The request id.

        ***********************************************************************/

        private RequestId id;

        /***********************************************************************

            The serialised request context data. This is passed to the request
            handler, where it must be deserialized.

            This array is empty (not necessarily `null`) while this request is
            inactive.

        ***********************************************************************/

        private void[] context;

        /***********************************************************************

            The serialised request-on-conn working data. This is passed to the
            request handler, where it must be deserialized.

            This array is empty (not necessarily `null`) while this request is
            inactive.

        ***********************************************************************/

        private void[] initial_working_data;

        /***********************************************************************

            The set of RequestOnConn instances in use by this request. (This
            helper struct is defined at the end of this module.)

        ***********************************************************************/

        private RequestOnConnSet request_on_conns;

        /***********************************************************************

            Request implementation function to be called when the last handler
            of the request has finished.

        ***********************************************************************/

        private FinishedNotifier finished_notifier;

        /***********************************************************************

            UNIX wall clock time (in microseconds) at which this request
            was started.

        ***********************************************************************/

        private ulong start_time_micros;

        /***********************************************************************

            Consistency check when this instance is inactive.

        ***********************************************************************/

        invariant ( )
        {
            if (!this.id)
            {
                assert(!this.request_on_conns.is_all_nodes);
                assert(this.request_on_conns.single_node is null);
                assert(this.finished_notifier is null);
                assert(!this.request_on_conns.num_active);
                assert(!this.context.length);
            }
        }

        /***********************************************************************

            Constructor; initialises `this.single_node` to a zero address with a
            `null` handler.

            By default, i.e. as long as this request is inactive, the
            `single_node` field is active and has its init value, and
            is_all_nodes` is false. This for error/race condition robustness:
            Should `getHandler()` be accidentally called while this request is
            not active, it will apply well defined behaviour, find a zero
            address/port with a null handler, and return null.

        ***********************************************************************/

        public this ( )
        {
            this.request_on_conns.single_node =
                this.request_on_conns.single_node.init;
        }

        /***********************************************************************

            Returns:
                the type of the request: all_nodes, single_node, round_robin or
                none.

        ***********************************************************************/

        public Type type ( )
        {
            return this.handler.active;
        }

        /***********************************************************************

            Starts a single-node request.

            `handler` is called once in a fiber, receiving a delegate allowing
            it to use an `EventDispatcher` instance, for the specified
            connection, within a limited scope. After leaving the scope, the
            request handler may call the delegate again to receive another
            `EventDispatcher` to communicate with another node.

            Note that, when this method returns, `handler` may be in the
            suspended fiber, waiting for I/O to complete, or may have finished.

            Params:
                handler = request handler
                finished_notifier = called when the last hander has finished
                context = request context, must be a Contiguous-serialisable
                    struct
                working = initial working data to serialize into the request
                    connection

        ***********************************************************************/

        public void startSingleNode ( RequestContext, WorkingData )
            ( SingleNodeHandler handler, FinishedNotifier finished_notifier,
            RequestContext context, WorkingData working )
        {
            this.handler.single_node = handler;
            this.initRequest(finished_notifier, context, working);
            auto request_on_conn =
                this.request_on_conns.setSingle(this.outer.newRequestOnConn());
            request_on_conn.start(this.id, this.context,
                this.initial_working_data, &this.handlerFinished, handler);
        }

        /***********************************************************************

            Starts a single round-robin node request.

            `handler` is called once in a fiber, receiving an interface allowing
            it to iterate over the set of connections in round-robin order,
            receiving an `EventDispatcher` instance for each.

            Note that, when this method returns, `handler` may be in the
            suspended fiber, waiting for I/O to complete, or may have finished.

            Params:
                handler = request handler
                finished_notifier = called when the last hander has finished
                context = request context, must be a Contiguous-serialisable
                    struct
                working = initial working data to serialize into the request
                    connection

        ***********************************************************************/

        public void startRoundRobin ( RequestContext, WorkingData ) (
            RoundRobinHandler handler, FinishedNotifier finished_notifier,
            RequestContext context, WorkingData working )
        {
            this.handler.round_robin = handler;
            this.initRequest(finished_notifier, context, working);
            auto request_on_conn =
                this.request_on_conns.setSingle(this.outer.newRequestOnConn());
            request_on_conn.start(this.id, this.context,
                this.initial_working_data, &this.handlerFinished, handler);
        }

        /***********************************************************************

            Starts an all-nodes request.

            For `n` nodes `handler` is run in `n` fibers simultaneously where
            each handler receives a `EventDispatcher` object `m` to exchange
            request messages with one node.

            `handler` returns `bool`: If it returns `true` then it is restarted
            as soon as the connection is available; otherwise, by returning
            `false`, it indicates it is finished.

            `finished_notifier` is called when the last handler has finished and
            its fiber is about to terminate.

            Note that, when this method returns, the multiple instances of
            `handler` may be in the suspended fiber, waiting for I/O to
            complete, or may have finished. `all_nodes_finished` may be called
            before this method returns or after it has returned.

            Params:
                handler = request handler
                finished_notifier = called when the last hander has finished
                context = request context, must be a Contiguous-serialisable
                    struct
                working = initial working data to serialize into the request
                    connections

        ***********************************************************************/

        public void startAllNodes ( RequestContext, WorkingData )
            ( AllNodesHandler handler, FinishedNotifier finished_notifier,
            RequestContext context, WorkingData working )
        {
            this.handler.all_nodes = handler;
            this.initRequest(finished_notifier, context, working);

            this.request_on_conns.all_nodes.reinit();
            this.request_on_conns.is_all_nodes = true;

            foreach (connection; this.outer.connections)
            {
                auto request_on_conn = this.request_on_conns.addMulti(
                    connection.remote_address, this.outer.newRequestOnConn());
                request_on_conn.start(this.id, this.context,
                    this.initial_working_data, &this.handlerFinished, handler,
                    connection);
            }
        }

        /***********************************************************************

            Adds a request-on-conn for an all nodes request, starting the
            request on a newly added node connection.

            Params:
                connection = connection to start the new request-on-conn for. If
                    the request is already running on the specified connection,
                    nothing changes

            In:
                this.id must not be 0, the request must be in the set of active
                requests, and the type of the request must be all-nodes

        ***********************************************************************/

        public void startOnNewConnection ( Connection connection )
        in
        {
            assert(this.id);
            assert(this.type == Type.all_nodes);

            auto rq = this.id in this.outer.active_requests;

            assert(rq !is null);
            assert(*rq is this);
        }
        body
        {
            if ( this.getHandler(connection.remote_address) !is null )
                return;

            auto request_on_conn = this.request_on_conns.addMulti(
                connection.remote_address, this.outer.newRequestOnConn());
            request_on_conn.start(this.id, this.context,
                this.initial_working_data, &this.handlerFinished,
                this.handler.all_nodes, connection);
        }

        /***********************************************************************

            Obtains the handler of this request that is currently communicating
            with a node, if any.

            Params:
                node_address = the address of the node to look up the handler
                               for

            Returns:
                the handler of this request that is currently communicating with
                the node or null if none is doing that right now.

        ***********************************************************************/

        public RequestOnConn getHandler ( IPAddress node_address )
        {
            if (this.request_on_conns.is_all_nodes)
            {
                return node_address.cmp_id in this.request_on_conns.all_nodes;
            }
            else if (this.request_on_conns.single_node !is null)
            {
                return this.request_on_conns.single_node.connectedTo(node_address)
                    ? this.request_on_conns.single_node
                    : null;
            }
            else
            {
                return null;
            }
        }

        /***********************************************************************

            IRequestController method. Gets the request's context blob.

            Returns:
                the context blob of this request

        ***********************************************************************/

        public void[] context_blob ( )
        {
            return this.context;
        }

        /***********************************************************************

            IRequestController method. Resumes any handler fibers of this
            request which are currently suspended. The specified code is
            returned from the call to suspend() which caused them to yield. Note
            that running fibers are not affected.

            Params:
                resume_code = code to pass to the resume() call, which will be
                    returned by the suspend() calls which caused the handler
                    fibers to yield

        ***********************************************************************/

        public void resumeSuspendedHandlers ( int resume_code )
        {
            if (this.request_on_conns.is_all_nodes)
            {
                foreach ( request_on_conn; this.request_on_conns.all_nodes )
                {
                    if ( !request_on_conn.is_running )
                        request_on_conn.resumeFiber(resume_code);
                }
            }
            else
            {
                if ( !this.request_on_conns.single_node.is_running )
                    this.request_on_conns.single_node.resumeFiber(resume_code);
            }
        }

        /***********************************************************************

            Aborts the request-on-conn fibers of this request by causing them to
            be resumed and throwing an exception inside them.

            Note that this method should not be called from within one of the
            request-on-conn fibers of the request to be aborted.

            Params:
                reason = reason for aborting the request

        ***********************************************************************/

        private void abortSuspendedHandlers ( RequestOnConn.AbortReason reason )
        {
            if (this.request_on_conns.is_all_nodes)
            {
                foreach ( request_on_conn; this.request_on_conns.all_nodes )
                {
                    assert(!request_on_conn.is_running,
                        "abort() may not be called from within one of the request's fibers");
                    request_on_conn.abort(reason);
                }
            }
            else
            {
                assert(!this.request_on_conns.single_node.is_running,
                    "abort() may not be called from within one of the request's fibers");
                this.request_on_conns.single_node.abort(reason);
            }
        }

        /***********************************************************************

            IRequestController method. Passes an IRequestWorkingData iterator to
            the provided delegate, granting access to the working data of each
            request-on-conn of this request.

            Params:
                dg = delegate to receive the working data iterator

        ***********************************************************************/

        public void accessRequestWorkingData (
            void delegate ( IRequestWorkingData ) dg )
        {
            scope working_data_iter = new RequestWorkingData;
            dg(working_data_iter);
        }

        /***********************************************************************

            Serialises handler_param into `this.request_context`.
            After serialisation `this.request_context` is deserialised so that
            it can be read by just casting its `ptr` to `HandlerParam`.

            Params:
                request_context = context of request

            In:
                `this.request_context` is expected to be empty (i.e. was
                properly reset if used before).

        ***********************************************************************/

        private void serializeRequestContext ( T ) ( ref T request_context )
        in
        {
            assert(!this.context.length, typeof(this).stringof ~
                   "serializeRequestContext: this.context.length expected" ~
                   " to be 0 as it ought to be if it was properly reset");
        }
        body
        {
            Serializer.serialize(request_context, this.context);
            Deserializer.deserialize!(T)(this.context);
        }

        /***********************************************************************

            Serialises `working` into `this.initial_working_data`.
            After serialisation `this.initial_working_data` is deserialised so
            that it can be read by just casting its `ptr` to `T`.

            Params:
                working = working data of request

            In:
                `this.initial_working_data` is expected to be empty (i.e. was
                properly reset if used before).

        ***********************************************************************/

        public void serializeWorkingData ( T ) ( ref T working )
        in
        {
            assert(!this.initial_working_data.length, typeof(this).stringof ~
                   "serializeWorkingData: this.working_data.length expected" ~
                   " to be 0 as it ought to be if it was properly reset");
        }
        body
        {
            Serializer.serialize(working, this.initial_working_data);
            Deserializer.deserialize!(T)(this.initial_working_data);
        }

        /***********************************************************************

            Looks up the Connection object which can be used to exchange request
            messages with a node.

            Params:
                node_address    = the address of the node to communicate with

            Returns:
                the connection to the node or `null` if currently not connected
                to this node.

        ***********************************************************************/

        public Connection getConnectionForSingleNode ( IPAddress node_address )
        in
        {
            assert(!this.request_on_conns.is_all_nodes);
        }
        body
        {
            return this.outer.connections.get(node_address);
        }

        /***********************************************************************

            Recycles `request_on_conn` and decreases the counter of currently
            active request. Finalises this request if that counter reaches 0:
             - calls the request-finished notifier,
             - removes this request from the request set,
             - resets this instance.

            Called exactly once by each request handler, after the client's
            request handler has terminated (by returning or throwing) and the
            fiber is about to terminate.

            Params:
                request_on_conn = the request-on-connection that is finishing

        ***********************************************************************/

        public void handlerFinished ( RequestOnConn request_on_conn )
        in
        {
            assert(this.request_on_conns.num_active);
            if ( !this.request_on_conns.is_all_nodes )
                assert(this.request_on_conns.num_active == 1);
        }
        body
        {
            this.request_on_conns.finished(request_on_conn);

            if (!this.request_on_conns.num_active)
            {
                scope working_data_iter = new RequestWorkingData;
                this.finished_notifier(this.context, working_data_iter);

                /*
                 * Reset to default behaviour: A mock single-node request with
                 * zero address/port and null request handler.
                 */
                this.outer.requestFinished(this);
                this.reset();
            }
        }

        /***********************************************************************

            Common request initialisation boiler-plate shared by the start*()
            methods, above.

            Params:
                finished_notifier = called when the last hander has finished
                context = request context, must be a Contiguous-serialisable
                    struct
                working = initial working data to serialize into the request
                    connections

            In:
                this.id must not be 0, nor may there be handlers running. The
                request must be in the set of active requests.

        ***********************************************************************/

        private void initRequest (RequestContext, WorkingData )
            ( FinishedNotifier finished_notifier, RequestContext context,
            WorkingData working )
        in
        {
            assert(this.id);
            assert(!this.request_on_conns.num_active);

            auto rq = this.id in this.outer.active_requests;

            assert(rq !is null);
            assert(*rq is this);
        }
        body
        {
            this.serializeRequestContext(context);
            this.serializeWorkingData(working);
            this.finished_notifier = finished_notifier;
            this.start_time_micros = MicrosecondsClock.now_us();
        }

        /***********************************************************************

            Resets this instance to make the request inactive (see constructor
            documentation), and resets `this.request_context`.

        ***********************************************************************/

        private void reset ( )
        out
        {
            assert(this); // invariant
        }
        body
        {
            this.id = 0;
            this.request_on_conns.reset(&this.outer.request_on_conn_pool.recycle);
            this.finished_notifier = null;
            // Reset this.context like Contiguous.reset() does it.
            this.context.length = 0;
            enableStomping(this.context);
            this.initial_working_data.length = 0;
            enableStomping(this.initial_working_data);
        }
    }

    /**************************************************************************/

    import swarm.neo.util.FixedSizeMap;
    import swarm.neo.client.requests.Timeouts;
    import swarm.neo.client.requests.Stats;
    import ocean.util.container.pool.ObjectPool;
    import ocean.util.container.ebtree.nodepool.NodePool: NodePool;
    import ocean.io.select.EpollSelectDispatcher;

    /***************************************************************************

        The map of currently active requests.

    ***************************************************************************/

    private alias FixedSizeMap!(Request, RequestId) RequestMap;
    private RequestMap active_requests;

    /***************************************************************************

        Pool of the request handlers.

    ***************************************************************************/

    private alias ObjectPool!(RequestOnConn) RequestOnConnPool;
    private RequestOnConnPool request_on_conn_pool;

    /***************************************************************************

        The set of connections by node.

    ***************************************************************************/

    private ConnectionSet connections;

    /***************************************************************************

        Request timeout manager instance.

    ***************************************************************************/

    private Timeouts timeouts;

    /***************************************************************************

        Request stats tracker instance.

    ***************************************************************************/

    private Stats stats_;

    /***************************************************************************

        Reused exception, instantiated on demand.

    ***************************************************************************/

    private NoMoreRequests e_no_more_requests;

    /***************************************************************************

        The global request ID, a counter. IDs assigned to requests are never 0
        (so this counter in incremented before using it for a new request).

    ***************************************************************************/

    private static RequestId global_request_id = 0;

    /***************************************************************************

        Constructor.

        Params:
            connections = the set of connections
            epoll = epoll instance, required by the timeout manager

    ***************************************************************************/

    public this ( ConnectionSet connections, EpollSelectDispatcher epoll )
    {
        this.connections = connections;
        this.active_requests = new RequestMap(typeof(this).max_requests);
        this.request_on_conn_pool = new RequestOnConnPool;
        this.timeouts = new Timeouts(epoll, &this.requestTimedOut);
        this.stats_ = new Stats;
    }

    /***************************************************************************

        Called from the public client API.
        Starts a single-node request, calling `handler` in a fiber, passing a
        `RequestOnConn`, which `handler` should use to exchange request
        messages with a node.

        Params:
            handler = request handler
            finished_notifier = called when the last hander has finished
            context = handler specific request context; `handler` can obtain
                      these from the `RequestOnConn` it receives
            working = initial working data to serialize into the request
                connection

        Throws:
            NoMoreRequests if starting a new request would exceed the maximum
            allowed number of active requests at a time.

    ***************************************************************************/

    public RequestId startSingleNode ( RequestContext, WorkingData ) (
        SingleNodeHandler handler, Request.FinishedNotifier finished_notifier,
        RequestContext context, WorkingData working )
    {
        assert(handler !is null);
        assert(finished_notifier !is null);

        auto rq = this.newRequest();
        assert(rq.id > 0);
        context.request_id = rq.id;
        rq.startSingleNode(handler, finished_notifier, context, working);
        return rq.id;
    }

    /***************************************************************************

        Called from the public client API.
        Starts a single round-robin node request, calling `handler` in a fiber,
        passing a `RequestOnConn.RoundRobinEventDispatcher`, which `handler`
        should use to exchange request messages with a node.

        Params:
            handler = request handler
            finished_notifier = called when the last hander has finished
            context = handler specific request context; `handler` can obtain
                      these from the `RequestOnConn` it receives
            working = initial working data to serialize into the request
                connection

        Throws:
            NoMoreRequests if starting a new request would exceed the maximum
            allowed number of active requests at a time.

    ***************************************************************************/

    public RequestId startRoundRobin ( RequestContext, WorkingData ) (
        RoundRobinHandler handler, Request.FinishedNotifier finished_notifier,
        RequestContext context, WorkingData working )
    {
        assert(handler !is null);
        assert(finished_notifier !is null);

        auto rq = this.newRequest();
        assert(rq.id > 0);
        context.request_id = rq.id;
        rq.startRoundRobin(handler, finished_notifier, context, working);
        return rq.id;
    }

    /***************************************************************************

        Called from the public client API.
        Starts an all-nodes request, calling `handler` in as many fibers as
        there are nodes currently in the registry, passing a
        `RequestOnConn.EventDispatcher`, which `handler` should use to
        exchange request messages with a node.

        Params:
            handler = request handler
            finished_notifier = called when the last hander has finished
            context = handler specific request context; `handler` can obtain
                      these from the `RequestOnConn.EventDispatcher` it
                      receives
            working = initial working data to serialize into the request
                connections

        Throws:
            NoMoreRequests if starting a new request would exceed the maximum
            allowed number of active requests at a time.

    ***************************************************************************/

    public RequestId startAllNodes ( RequestContext, WorkingData ) (
        AllNodesHandler handler, Request.FinishedNotifier finished_notifier,
        RequestContext context, WorkingData working )
    {
        assert(handler !is null);
        assert(finished_notifier !is null);

        auto rq = this.newRequest();
        assert(rq.id > 0);
        context.request_id = rq.id;
        rq.startAllNodes(handler, finished_notifier, context, working);
        return rq.id;
    }

    /***************************************************************************

        Returns:
            public interface to the request stats tracker

    ***************************************************************************/

    public IRequestStats stats ( )
    {
        return this.stats_;
    }

    /***************************************************************************

        Called by ConnectionSet when a new connection has been added. Any
        all-nodes requests which are currently active must be started on the new
        connection. This is achieved by calling Request.startOnNewConnection().

        Params:
            connection = newly added connection

    ***************************************************************************/

    public void newConnectionAdded ( ConnectionSet.Connection connection )
    {
        foreach ( id, rq; this.active_requests )
        {
            if ( rq.type == Request.Type.all_nodes )
            {
                rq.startOnNewConnection(connection);
            }
        }
    }

    /***************************************************************************

        Called by Connection when about to send or just received a request
        message. Gets the currently active request matching `id`, if there is
        one.

        Params:
            id = request id

        Returns:
            the currently active request matching `id` or null if there is none.

    ***************************************************************************/

    public IRequest getRequest ( RequestId id )
    {
        if ( auto rq = id in this.active_requests )
        {
            return *rq;
        }
        else
        {
            return null;
        }
    }

    /***************************************************************************

        Aborts the specified request. The request's request-on-conn fibers are
        killed and it is removed from the set of active requests. The node is
        not informed of this, though, and may have already received the initial
        message from the request and started handling it. In this case, any
        messages received from the node for this request will simply be ignored.

        Note that this method should not be called from within one of the
        request-on-conn fibers of the request to be aborted.

        Params:
            id = id of request to abort
            reason = reason for aborting the request

        Returns:
            true if the request was aborted; false if no active request could be
            found with the specified id

    ***************************************************************************/

    public bool abortRequest ( RequestId id, RequestOnConn.AbortReason reason )
    out
    {
        assert((id in this.active_requests) is null);
    }
    body
    {
        if ( auto rq = id in this.active_requests )
        {
            rq.abortSuspendedHandlers(reason);
            // Note that when all request-on-conn fibers have exited,
            // handlerFinished() is called. This removes the request from the
            // active set.

            return true;
        }
        else
        {
            return false;
        }
    }

    /***************************************************************************

        Gets the IRequestController interface to the currently active request
        matching `id`, if there is one.

        Params:
            id = request id
            expected_finished_notifier = the function which is expected to be
                the finished notifier of the request matching `id`. This
                argument is used as a sanity check that the specified request is
                of the expected type. The finished notifier function is the
                easiest way of identifying the type of a Request (there is a
                unique finished notifier function per request type)

        Returns:
            the controller interface for the currently active request matching
            `id` or null if there is none.

    ***************************************************************************/

    public IRequestController getRequestController ( RequestId id,
        Request.FinishedNotifier expected_finished_notifier )
    {
        if ( auto rq = id in this.active_requests )
        {
            assert(rq.finished_notifier == expected_finished_notifier,
                "Controller does not match specified request");
            return *rq;
        }
        else
        {
            return null;
        }
    }

    /***************************************************************************

        Sets the request with the specified id to timeout after the specified
        number of microseconds, if it has not finished normally.

        Params:
            id = id of request to set a timeout for
            timeout_micros = microseconds timeout value to set

    ***************************************************************************/

    public void setRequestTimeout ( RequestId id, ulong timeout_micros )
    {
        this.timeouts.setRequestTimeout(id, timeout_micros);
    }

    /***************************************************************************

        Returns:
            the number of active requests

    ***************************************************************************/

    public size_t num_active ( )
    {
        return this.active_requests.length;
    }

    /***************************************************************************

        Returns:
            an inactive `Request`.

        Throws:
            NoMoreRequests if starting a new request would exceed the maximum
            allowed number of active requests at a time.

    ***************************************************************************/

    private Request newRequest ( )
    {
        if ( this.active_requests.length < typeof(this).max_requests )
        {
            Request* rqp = this.active_requests.add(++typeof(this).global_request_id);

            if (*rqp is null)
            {
                *rqp = this.new Request;
            }
            Request request = *rqp;
            assert(request); // also call the invariant
            assert(!request.id, "new request expected to be inactive");
            request.id = this.global_request_id;
            return request;
        }
        else
        {
            if (this.e_no_more_requests is null)
            {
                this.e_no_more_requests = new NoMoreRequests;
            }

            throw this.e_no_more_requests;
        }
    }

    /***************************************************************************

        Delegate passed to the ctor of the request timeout manager
        (this.timeouts). Called when a request times out and must be aborted.

        Params:
            id = id of the request which has timed out and must be aborted

    ***************************************************************************/

    private void requestTimedOut ( RequestId id )
    {
        this.abortRequest(id, RequestOnConn.AbortReason.Timeout);
    }

    /***************************************************************************

        Called from Request.handlerFinished(). Clears all state owned by
        RequestSet for the specified request.

        Params:
            request = the request which has finished and should be forgotten

    ***************************************************************************/

    private void requestFinished ( Request request )
    {
        this.stats_.requestFinished(request.finished_notifier,
            request.start_time_micros);
        this.timeouts.clearRequestTimeout(request.id);
        this.active_requests.removeExisting(request.id);
    }

    /***************************************************************************

        Returns:
            a new `RequestOnConn` object.

    ***************************************************************************/

    private RequestOnConn newRequestOnConn ( )
    {
        return this.request_on_conn_pool.get(new RequestOnConn(this.connections));
    }

    /***************************************************************************

        Throw if starting a new request would exceed the maximum allowed number
        of active requests at a time.

    ***************************************************************************/

    static class NoMoreRequests: Exception
    {
        this ( istring file = __FILE__, typeof(__LINE__) line = __LINE__ )
        {
            super("Attepted to start more than " ~ max_requests.stringof ~
                  " requests, which is the maximum allowed number", file, line);
        }
    }
}
