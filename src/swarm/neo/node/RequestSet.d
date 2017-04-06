/*******************************************************************************

    Registry of currently active requests.

    The size of the registry must be limited to avoid leaking resources (memory)
    if, for whatever reason, a client start more requests than finish over a
    long time.
    If the limit of simultaneous requests is exceeded, the request with the
    least recent exchange of messages between the node and the client is
    dropped. The node should be configured so that this can only happen in
    extreme situations or in case of a bug in the client.

    Copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.node.RequestSet;

import ocean.util.container.pool.ObjectPool;

import ocean.transition;

/******************************************************************************/

class RequestSet
{
    import swarm.neo.node.RequestOnConn;
    import swarm.neo.node.Connection;
    import swarm.neo.protocol.Message: RequestId;
    import swarm.neo.connection.YieldedRequestOnConns;

    /***************************************************************************

        The class for an active request.

    ***************************************************************************/

    static class Request: RequestOnConn
    {
        /***********************************************************************

            The ebtree node for `Request.active_requests`.

        ***********************************************************************/

        struct TreeMapElement
        {
            import ocean.util.container.ebtree.c.eb64tree: eb64_node;
            eb64_node ebtnode;
            Request request;

            alias request user_element_with_treemap_backlink;
        }

        /***********************************************************************

            The ebtree node while this instance is registered in
            `Request.active_requests`.

        ***********************************************************************/

        public TreeMapElement* treemap_backlink = null;

        /***********************************************************************

            Object pool index.

        ***********************************************************************/

        public size_t object_pool_index;

        /***********************************************************************

            A flag telling whether `this.fiber` has been running before. If true
            then the fiber should be in the "finished"/`TERM` state when this
            request is started, otherwise it is in the "waiting"/`HOLD` state.

        ***********************************************************************/

        private bool fiber_was_started = false;

        /***********************************************************************

            The request set with which this instance is registered while the
            handler is running. It is null if the handler is not running.

        ***********************************************************************/

        private RequestSet request_set;

        /***********************************************************************

            Constructor.

            Params:
                yielded_rqonconns = resumes yielded `RequestOnConn`s

        ***********************************************************************/

        public this ( YieldedRequestOnConns yielded_rqonconns )
        {
            super(yielded_rqonconns);
        }

        /***********************************************************************

            Sets the id of this request to `request_id`.

        ***********************************************************************/

        public RequestId id ( RequestId request_id )
        {
            return this.request_id = request_id;
        }

        /***********************************************************************

            Returns:
                the id of this request

        ***********************************************************************/

        public RequestId id ( ) /* d1to2fix_inject: const */
        {
            return this.request_id;
        }

        /***********************************************************************

            Called when ready to send a message for this request.

            Outputs the payload of the request message to the send callback,
            then resumes the fiber.

            Params:
                send = callback to pass the payload to send to

            In:
                This instance must have a payload to send.

        ***********************************************************************/

        override public void getPayloadForSending ( void delegate ( void[][] payload ) send )
        {
            super.getPayloadForSending(send);
        }

        /***********************************************************************

            Called when a message for this request has arrived.

            Stores a slice to the received message payload, then starts or
            resumes the fiber.

            Params:
                payload = the received message payload

            In:
                payload must not be null.

        ***********************************************************************/

        override public void setReceivedPayload ( Const!(void)[] payload )
        {
            super.setReceivedPayload(payload);
        }

        /***********************************************************************

            Assigns the request id, connection and the request set with which
            this request is registered after this instance was newly created or
            fetched from the object pool.

            This method must be called before the request handler is called.
            `runHandler()` resets this instance when the request handler exits
            (returns or throws).

            Params:
                id          = the request id
                connection  = the client connection
                request_set = the request set with which this instance is
                              registered

        ***********************************************************************/

        public void setup ( RequestId id, Connection connection, RequestSet request_set )
        in
        {
            /* final */ switch (this.fiber.state)
            {
                case fiber.state.HOLD:
                    assert(!this.fiber_was_started,
                           "Request unexpectedly running (fiber suspended)");
                    goto case;

                case fiber.state.TERM:
                    break;

                case fiber.state.EXEC:
                default:
                    assert(false, "Request unexpectedly running (fiber executing)");
            }

            assert(!this.request_id, "previous request id wasn't reset");
            assert(!this.request_set, "previous request set wasn't reset");
            assert(!this.connection, "previous connection wasn't reset");
        }
        body
        {
            this.request_id  = id;
            this.request_set = request_set;
            this.connection  = connection;
        }

        /***********************************************************************

            Called by the connection to report an error which requires aborting
            this request.

        ***********************************************************************/

        alias resumeFiber error;

        /***********************************************************************

            Resumes the fiber or starts it if it is new or terminated.

        ***********************************************************************/

        override protected void resumeFiber_ ( fiber.Message msg )
        {
            /* final */ switch (this.fiber.state)
            {
                case fiber.state.HOLD:
                    if (this.fiber_was_started)
                    {
                        super.resumeFiber_(msg);
                        break;
                    }
                    else
                    {
                        this.fiber_was_started = true;
                        goto case;
                    }

                case fiber.state.TERM:
                    this.fiber.start(msg);
                    break;

                case fiber.state.EXEC:
                default:
                    assert(false, "Request unexpectedly running (fiber executing)");
            }
        }

        /***********************************************************************

            The fiber method. Calls the node specific request handler with this
            instance and the payload of the first message from the client for
            this request.

        ***********************************************************************/

        override protected void runHandler ( )
        {
            try
            {
                /*
                 * Reset this.recv_payload before calling the handler so that
                 * the handler can receive messages without needing to reset it
                 * by itself.
                 */
                auto recv_payload = this.recv_payload_;
                this.recv_payload_ = null;
                this.request_set.handler(this, recv_payload);
            }
            finally
            {
                this.request_set.removeRequest(this);
                this.request_id  = 0;
                this.request_set = null;
                this.connection  = null;
            }
        }
    }

    /**************************************************************************/

    import swarm.neo.util.TreeMap;
    import ocean.util.container.ebtree.c.eb64tree: eb64_node;

    /***************************************************************************

        The map of currrently active requests.

    ***************************************************************************/

    private TreeMap!(Request.TreeMapElement) active_requests;

    /***************************************************************************

        The number of elements in `active_requests`.

    ***************************************************************************/

    private uint n_active_requests = 0;

    /***************************************************************************

        The pool of request objects.

    ***************************************************************************/

    alias ObjectPool!(Request) RequestPool;

    private RequestPool request_pool;

    /***************************************************************************

        Resumes yielded `RequestOnConn`s.

    ***************************************************************************/

    private YieldedRequestOnConns yielded_rqonconns;

    /***************************************************************************

        The associated connection.

    ***************************************************************************/

    private Connection connection;

    /***************************************************************************

        The request handler.

    ***************************************************************************/

    alias void delegate ( RequestOnConn handler,
        Const!(void)[] init_payload = null ) Handler;

    private Handler handler;

    /***************************************************************************

        The maximum number of requests this instance must be a able to handle
        simultaneously.

    ***************************************************************************/

    private const max_requests = 5_000;

    /***************************************************************************

        Constructor.

        Whenever a request is started by the client on connection, handler is
        called in its own fiber with a Request object and the first request
        message payload received from the client.

        Params:
            connection   = the connection using and used by this request set
            request_pool = the pool of `Request` objects to use
            yielded_rqonconns = resumes yielded `RequestOnConn`s
            handler      = the node specific request handler

    ***************************************************************************/

    public this ( Connection connection, RequestPool request_pool,
                  YieldedRequestOnConns yielded_rqonconns, Handler handler )
    {
        this.connection = connection;
        this.handler = handler;
        this.request_pool = request_pool;
        this.yielded_rqonconns = yielded_rqonconns;
    }

    /***************************************************************************

        Obtains the Request object corresponding to id or creates a new one if
        not found.
        If this method is called while the number of active request is
        max_requests, the request with the least recent call to send() or
        receive() will be aborted.

        Params:
            id = request id

        Returns:
            the Request object corresponding to id.

        Throws:
            ProtocolError if attempting to start a new request, which would
            exceed the limit of the number of requests per connection.

        Out:
            - The returned object is in a good shape, and its id is id.
            - The number of requests for this connection is in range.

    ***************************************************************************/

    public Request getOrCreateRequest ( RequestId id )
    out (request)
    {
        assert(request);
        assert(request.id == id);
        assert(this.n_active_requests <= max_requests);
    }
    body
    {
        bool added;
        auto request = this.active_requests.put(
            id, added, this.request_pool.get(new Request(this.yielded_rqonconns))
        );

        if (added)
        {
            if (this.n_active_requests >= max_requests)
            {
                this.active_requests.remove(request);
                throw this.connection.protocol_error.set(
                    "Limit of requests per connection exceeded"
                );
            }

            request.setup(id, this.connection, this);
            this.n_active_requests++;
        }

        return request;
    }

    /***************************************************************************

        Obtains the `Request` object corresponding to id.

        Params:
            id = request id

        Returns:
            the Request object corresponding to id if found or null otherwise.

    ***************************************************************************/

    public Request getRequest ( RequestId id )
    {
        return id in this.active_requests;
    }

    /***************************************************************************

        Shutdowns all active requests.

        This method is called by the connection object if an I/O or protocol
        error happens in order to shut down all active requests.

        This method should not throw.

        Params:
            e  = the exception reflecting the reason for the shutdown

    ***************************************************************************/

    public void shutdownAll ( Exception e )
    {
        foreach (req; this.active_requests)
        {
            req.error(e);
        }
    }

    /***************************************************************************

        Removes the `Request` object corresponding to id from the registry of
        active requests if is registered.

        Params:
            id = request id

    ***************************************************************************/

    private void removeRequest ( Request request )
    {
        this.active_requests.remove(request);
        this.request_pool.recycle(request);
        this.n_active_requests--;
    }
}
