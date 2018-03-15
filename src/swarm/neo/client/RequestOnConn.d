/*******************************************************************************

    Full-duplex client connection handler.

    For requests that use a single node at a time a `RequestOnConn` object
    `r` is passed to the client's request handler, which runs in a fiber. To
    exchange request messages with a node the request handler should create a
    `scope e = r.new EventDispatcher(node_address)` object. Per RequestOnConn at
    most one EventDispatcher object may exist at a time. After leaving the scope
    of `e` the request handler may create another `r.new EventDispatcher` to
    communicate with another node.

    For requests that use all n nodes the client's request handler is run in n
    fibers simultaneously where each handler receives a EventDispatcher
    object to exchange request messages with one node.

    Copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.neo.client.RequestOnConn;

/******************************************************************************/

import swarm.neo.connection.RequestOnConnBase;
import swarm.neo.client.IRequestSet;

/*******************************************************************************

    This class inherits the following public API properties:

     - `recv_payload` and `send_payload` class variables
     - `suspendFiber` and `resumeFiber` class methods

*******************************************************************************/

public class RequestOnConn: RequestOnConnBase, IRequestOnConn
{
    import swarm.neo.AddrPort;
    import swarm.neo.client.RequestHandlers;
    import swarm.neo.client.Connection;
    import swarm.neo.connection.YieldedRequestOnConns;
    import ocean.transition;

    /***************************************************************************

        Additional fiber resume code.

    ***************************************************************************/

    public const FiberResumeCodeReconnected = FiberResumeCode.min - 1;

    /***************************************************************************

        Interface to the connection set. Provides the methods required by
        RequestOnConn (getting connections required by the request).

    ***************************************************************************/

    public interface IConnectionGetter
    {
        /***********************************************************************

            Gets the connection associated with the specified address.

            Params:
                node_address = the address of the node to get the connection for

            Returns:
                the corresponding Connection or null if the node is not known

        ***********************************************************************/

        Connection get ( AddrPort );

        /***********************************************************************

            Iterates over available connections, starting with a different
            connection on each iteration.

            Params:
                dg = called for each connection iterating over; should return 0
                    to continue or non-zero to stop the iteration

            Returns:
                0 if finished iterating over all nodes or the return value of
                `dg` if `dg` returned non-zero to stop the iteration.

        ***********************************************************************/

        int iterateRoundRobin ( int delegate ( Connection conn ) dg );
    }

    /***************************************************************************

        Adds a facility to wait for the connection to be reestablished if it
        broke to `EventDispatcher`.

    ***************************************************************************/

    public class EventDispatcherAllNodes: EventDispatcher
    {
        /***********************************************************************

            Convenience alias, needed to interpret the return code of
            `waitForReconnect`.

        ***********************************************************************/

        alias RequestOnConn.FiberResumeCodeReconnected FiberResumeCodeReconnected;

        /***********************************************************************

            Returns:
                status of the connection used by this request-on-conn (i.e.
                Disconnected, Connecting, Connected, Shutdown)

        ***********************************************************************/

        public Connection.Status connection_status ( )
        {
            return this.connection.status();
        }

        /***********************************************************************

            Waits for the connection to be reestablished if it is down.

            You can resume the fiber while it is suspended waiting for the
            connection to be reestablished.

            Returns:
                - FiberResumeCodeReconnected if the connection was down and has
                  been reestablished,
                - 0 if the connection was up so there was nothing to do,
                - your fiber resume code if you resumed the fiber while waiting
                  for the connection to be reestablished.

        ***********************************************************************/

        public int waitForReconnect ( )
        {
            if (!this.connection.registerForConnectedNotification(this.request_id))
                return 0;

            int resume_code = this.outer.suspendFiber();

            switch (resume_code)
            {
                case FiberResumeCodeReconnected:
                    break;

                default:
                    this.connection.unregisterForConnectedNotification(this.request_id);
                    break;

                case FiberResumeCode.Sent,
                     FiberResumeCode.Received:
                    assert(false, "Fiber resume code expected not to be Sent " ~
                                  "or Received");
            }

            return resume_code;
        }

        /***********************************************************************

            Copies of protected `this.outer` base class properties, which are
            inaccessible from this class.

        ***********************************************************************/

        private RequestId request_id;
        private Connection connection;

        private this ( RequestId request_id, Connection connection )
        {
            this.request_id = request_id;
            this.connection = connection;
        }
    }

    /***************************************************************************

        Helper class passed to a node-round-robin request. Provides an iterator
        which allows the handler to get an EventDispatcher set up for each
        connection in turn.

    ***************************************************************************/

    private final class EventDispatcherRoundRobin : IRoundRobinConnIterator
    {
        /***********************************************************************

            The event dispatcher to pass to the `foreach` loop body.

        ***********************************************************************/

        private EventDispatcher ed;

        /***********************************************************************

            Constructor.

            Params:
                ed = the event dispatcher to pass to the `foreach` loop body

        ***********************************************************************/

        public this ( EventDispatcher ed )
        {
            this.ed = ed;
        }

        /***********************************************************************

            `foreach` iteration over all nodes in round-robin fashion. `ed` is
            connected to the node of the current iteration cycle. Each iteration
            as a whole starts with a random node.

        ***********************************************************************/

        public int opApply ( int delegate ( ref EventDispatcher ed ) dg )
        {
            assert(this.outer.connection is null,
                   typeof(this).stringof ~ ".opApply: " ~
                   "This request is already using a node connection");

            return this.outer.connections.iterateRoundRobin(
                (Connection conn)
                {
                    this.outer.connection = conn;
                    return dg(this.ed);
                }
            );
        }
    }

    /***************************************************************************

        The `RequestOnConnByNode` ebtree node.

    ***************************************************************************/

    public struct TreeMapElement
    {
        import ocean.util.container.ebtree.c.eb64tree: eb64_node;
        eb64_node ebtnode;
        RequestOnConn request_on_conn;

        alias request_on_conn user_element_with_treemap_backlink;
    }

    /***************************************************************************

        The ebtree node associated with this instance. Allows it to be added to
        a TreeMap. Used when this instance is registered in `Request.all_nodes`.

    ***************************************************************************/

    public TreeMapElement* treemap_backlink = null;

    /***************************************************************************

        Object pool index.

    ***************************************************************************/

    public size_t object_pool_index;

    /***************************************************************************

        Used by `RequestOnConnSet`.

    ***************************************************************************/

    public bool active;

    /***************************************************************************

        Serialised request context data, set when starting a new request and
        passed to all request handlers when the request fiber is started.

    ***************************************************************************/

    private void[] request_context = null;

    /***************************************************************************

        Client request handler to start in a fiber.

    ***************************************************************************/

    private HandlerUnion handler;

    /***************************************************************************

        Delegate to be called when the handler is finished.

    ***************************************************************************/

    private alias void delegate ( typeof(this) ) HandlerFinishedDg;

    private HandlerFinishedDg finished_dg;

    /***************************************************************************

        Interface to the set of connections, allowing connections to be got or
        iterated over.

    ***************************************************************************/

    private IConnectionGetter connections;

    /***************************************************************************

        Codes set in an AbortException describing the reason for aborting a
        request-on-conn.

    ***************************************************************************/

    public enum AbortReason
    {
        /// The request was aborted due to a timeout
        Timeout
    }

    /***************************************************************************

        Exception class thrown to abort a request-on-conn. Exceptions of this
        type may be caught (e.g. in order to notify the user), but should always
        be rethrown, to exit the request handler.

    ***************************************************************************/

    private static class AbortException : Exception
    {
        /***********************************************************************

            Reason for aborting the request-on-conn.

        ***********************************************************************/

        public AbortReason reason;

        /***********************************************************************

            Constructor.

        ***********************************************************************/

        public this ( )
        {
            super("RequestOnConn aborted");
        }

        /***********************************************************************

            Sets the reason, file, and line fields and returns the exception.

            Params:
                reason = reason for aborting the request-on-conn
                file = name of file where exception is initialised
                line = line of file where exception is initialised

            Returns:
                this. Note that the instance is returned via a base-class
                reference in order to be able to use it unambiguously when
                initialising a MessageFiber.Message (the compiler doesn't know
                whether to treat an AbortException as an Exception or an
                Object).

        ***********************************************************************/

        public Exception opCall ( AbortReason reason, istring file = __FILE__,
            long line = __LINE__ )
        {
            this.reason = reason;
            this.file = file;
            this.line = line;

            return this;
        }
    }

    /***************************************************************************

        Re-usable AbortException instance.

    ***************************************************************************/

    private AbortException abort_exception;

    /// Delegate passed to multi-node request handler, allowing it to start the
    /// request on a new request-on-conn to a different node.
    private void delegate ( ) start_on_new_connection;

    /***************************************************************************

        Constructor.

        Params:
            connections = interface to the set of connections
            yielded_rqonconns = resumes yielded `RequestOnConn`s

    ***************************************************************************/

    public this ( IConnectionGetter connections,
        YieldedRequestOnConns yielded_rqonconns )
    {
        super(yielded_rqonconns);
        this.connections = connections;
        this.abort_exception = new AbortException;
    }

    /***************************************************************************

        Starts the request handler for a single-node request.

        Params:
            id = the request id
            context_blob = the opaque data stored as the request's context. This
                data is shared between all RoCs (sliced)
            finished_dg = delegate to be called when the handler is finished
            handler = the request handler to start in a fiber

        In:
            - No other handler must have been assigned already.

    ***************************************************************************/

    public void start ( RequestId id, void[] context_blob,
        HandlerFinishedDg finished_dg, SingleNodeHandler handler )
    in
    {
        assert(!this.handler.active);
    }
    body
    {
        this.setupRequest(id, context_blob, finished_dg);
        this.handler.single_node = handler;
        this.fiber.start();
    }

    /***************************************************************************

        Starts the request handler for a multi-node request.

        Params:
            id = the request id
            context_blob = the opaque data stored as the request's context. This
                data is shared between all RoCs (sliced)
            start_on_new_connection = delegate passed to the request handler,
                allowing it to start the request on a new request-on-conn to a
                different node
            finished_dg = delegate to be called when the handler is finished
            handler = the request handler to start in a fiber

        In:
            - No other handler must have been assigned already.

    ***************************************************************************/

    public void start ( RequestId id, void[] context_blob,
        void delegate ( ) start_on_new_connection,
        HandlerFinishedDg finished_dg, MultiNodeHandler handler )
    in
    {
        assert(!this.handler.active);
    }
    body
    {
        this.setupRequest(id, context_blob, start_on_new_connection, finished_dg);
        this.handler.multi_node = handler;
        this.fiber.start();
    }

    /***************************************************************************

        Starts the request handler for one node as a part of an all-nodes
        request.

        Params:
            id = the request id
            context_blob = the opaque data stored as the request's context. This
                data is shared between all RoCs (sliced)
            finished_dg = delegate to be called when the handler is finished
            handler    = the request handler to start in a fiber
            connection = the connection with which handler should communicate

        In:
            - No other handler must have been assigned already.

    ***************************************************************************/

    public void start ( RequestId id, void[] context_blob,
        HandlerFinishedDg finished_dg, AllNodesHandler handler, Connection connection )
    in
    {
        assert(!this.handler.active);
    }
    body
    {
        this.setupRequest(id, context_blob, finished_dg);
        this.handler.all_nodes = Handler.AllNodesWithConnection(connection,
            handler);
        this.fiber.start();
    }

    /***************************************************************************

        Starts the request handler for a single-node round-robin request.

        Params:
            id = the request id
            context_blob = the opaque data stored as the request's context. This
                data is shared between all RoCs (sliced)
            finished_dg = delegate to be called when the handler is finished
            handler = the request handler to start in a fiber

        In:
            - No other handler must have been assigned already.

    **************************************************************************/

    public void start ( RequestId id, void[] context_blob,
        HandlerFinishedDg finished_dg, RoundRobinHandler handler )
    in
    {
        assert(!this.handler.active);
    }
    body
    {
        this.setupRequest(id, context_blob, finished_dg);
        this.handler.round_robin = handler;
        this.fiber.start();
    }

    /***************************************************************************

        Aborts the request-on-conn, causing the waiting `suspendFiber()` call to
        throw an AbortException with the specified reason.

        Params:
            reason = reason for aborting the request-on-conn

    ***************************************************************************/

    public void abort ( AbortReason reason )
    {
        this.resumeFiber_(this.fiber.Message(this.abort_exception(reason)));
    }

    /***************************************************************************

        Fiber method. Calls the request handler delegate passed to start() and
        notifies the request via its handlerFinished() method, when finished.

    ***************************************************************************/

    override protected void runHandler ( )
    {
        scope (exit)
        {
            this.finished_dg(this);
            this.reset();
        }

        final switch (this.handler.active)
        {
            case handler.active.single_node:
                handler.single_node()(&this.useNode, this.request_context);
                break;

            case handler.active.multi_node:
                handler.multi_node()(&this.useNode,
                    this.start_on_new_connection, this.request_context);
                break;

            case handler.active.all_nodes:
                auto all_nodes = handler.all_nodes;
                this.connection = all_nodes.connection;
                scope ed = this.new EventDispatcherAllNodes(this.request_id, all_nodes.connection);
                all_nodes.dg(ed, this.request_context);
                break;

            case handler.active.round_robin:
                scope ed = this.new EventDispatcher;
                scope edrr = new EventDispatcherRoundRobin(ed);
                handler.round_robin()(edrr, this.request_context);
                break;

            case handler.active.none:
                assert(false);

            version (D_Version2) {} else default:
                assert(false);
        }
    }

    /***************************************************************************

        Called by `Connection` if the connection was reestablished, and this
        instance was registered for a notification of that event.

    ***************************************************************************/

    override public void reconnected ( )
    {
        this.resumeFiber_(fiber.Message(FiberResumeCodeReconnected));
    }

    /***************************************************************************

        Called by `Connection` when about to send a request message as
        requested by this instance.

        Params:
            send = the output delegate to call once with the message payload

    ***************************************************************************/

    override public void getPayloadForSending ( void delegate ( in void[][] payload ) send )
    {
        super.getPayloadForSending(send);
    }

    /***************************************************************************

        Called by `Connection` when a request message was received whose
        request id matches this.request.id.

        Params:
            payload = the payload of the received request message

    ***************************************************************************/

    override public void setReceivedPayload ( Const!(void)[] payload )
    {
        super.setReceivedPayload(payload);
    }

    /***************************************************************************

        Called by `Connection` if a protocol or I/O error happened on the
        connection currently used by this instance.

        Params:
            e = error information

    ***************************************************************************/

    override public void error ( Exception e )
    {
        this.resumeFiber(e);
    }

    /***************************************************************************

        Checks if currently connected to the node at `node_address`.

        Params:
            node_address = the node address in question

        Returns:
            true if currently connected to the node at `node_address` or
            false if not connected to this node.

    ***************************************************************************/

    public bool connectedTo ( AddrPort node_address )
    {
        return this.connection
            ? this.connection.remote_address == node_address
            : false;
    }

    /***************************************************************************

        Checks if the fiber is in `HOLD` state so it can be resumed.

        Returns:
            true if the fiber is in `HOLD` state or false if it is in `EXEC` or
            `TERM` state.

    ***************************************************************************/

    public bool can_be_resumed ( )
    {
        return this.fiber.state == fiber.state.HOLD;
    }

    /***************************************************************************

        Populates this instance with request parameters.

        Params:
            request = the request that called this.start().
            context_blob = the opaque data stored as the request's context. This
                data is shared between all RoCs (sliced)
            finished_dg = delegate to be called when the handler is finished

    ***************************************************************************/

    private void setupRequest ( RequestId id, void[] context_blob,
        HandlerFinishedDg finished_dg )
    {
        this.request_id = id;
        this.request_context = context_blob;
        this.finished_dg = finished_dg;
    }

    /***************************************************************************

        Populates this instance with request parameters.

        Params:
            request = the request that called this.start().
            context_blob = the opaque data stored as the request's context. This
                data is shared between all RoCs (sliced)
            start_on_new_connection = delegate passed to the request handler,
                allowing it to start the request on a new request-on-conn to a
                different node
            finished_dg = delegate to be called when the handler is finished

    ***************************************************************************/

    private void setupRequest ( RequestId id, void[] context_blob,
        void delegate ( ) start_on_new_connection,
        HandlerFinishedDg finished_dg )
    {
        this.request_id = id;
        this.request_context = context_blob;
        this.start_on_new_connection = start_on_new_connection;
        this.finished_dg = finished_dg;
    }

    /***************************************************************************

        Resets this instance after use. Called from runHandler(), when the fiber
        is about to exit.

    ***************************************************************************/

    private void reset ( )
    {
        this.handler = this.handler.init;
        this.connection = null;
    }

    /***************************************************************************

        A delegate reference to this method is passed to the single-node request
        handler.

        Instantiates an `EventDispatcher` for the specified node and passes it
        to the provided delegate for use by the request handler.

        Params:
            node_address = address of node to communicate with
            dg = delegate which receives the `EventDispatcher` instance for the
                 specified node. When the delegate exits, the event dispatcher
                 is destroyed.

        Returns:
            true on success or false if currently not connected to the specified
            node.

    ***************************************************************************/

    private bool useNode ( AddrPort node_address,
        void delegate ( EventDispatcher ed ) dg )
    {
        assert(this.connection is null,
               typeof(this).stringof ~ ".useNode: " ~
               "This request is already using a node connection");

        this.connection = this.connections.get(node_address);
        if (!this.connection)
            return false;

        scope (exit)
        {
            // the request may decide to use another connection, so we need to
            // reset this here to avoid asserting if this method is called again
            // from the handler
            this.connection = null;
        }
        scope ed = this.new EventDispatcher;
        dg(ed);
        return true;
    }
}
