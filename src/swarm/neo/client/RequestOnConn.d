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
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

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
    import swarm.neo.IPAddress;
    import swarm.neo.client.RequestHandlers;
    import swarm.neo.client.Connection;
    import ocean.transition;
    import ocean.util.serialize.contiguous.Contiguous;
    import ocean.util.serialize.contiguous.Serializer;
    import ocean.util.serialize.contiguous.Deserializer;

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
        Connection get ( IPAddress );
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

        Serialised request context data, set when starting a new request and
        passed to all request handlers when the request fiber is started.

    ***************************************************************************/

    private void[] request_context = null;

    /***************************************************************************

        Serialised working data, set when starting a new request and passed to
        all request handlers when the request fiber is started.

    ***************************************************************************/

    private void[] working_data = null;

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

    /***************************************************************************

        Constructor.

        Params:
            connections = interface to the set of connections

    ***************************************************************************/

    public this ( IConnectionGetter connections )
    {
        super(null);
        this.connections = connections;
        this.abort_exception = new AbortException;
    }

    /***************************************************************************

        Gets the serialised working data of this instance.

        Returns:
            working data of this request-on-conn

        In:
            `this.working_data` is expected to be non-empty (i.e. was
            properly set before use).

    ***************************************************************************/

    public Const!(void)[] getWorkingData ( )
    in
    {
        assert(this.working_data.length, typeof(this).stringof ~
            "getWorkingData: this.working_data.length expected" ~
            " to be > 0, as it ought to have been set at the start of the request");
    }
    body
    {
        return this.working_data;
    }

    /***************************************************************************

        Starts the request handler for a single-node request.

        Params:
            id = the request id
            context_blob = the opaque data stored as the request's context. This
                data is shared between all RoCs (sliced)
            working_blob = the opaque data owned by this RoC (copied internally)
            finished_dg = delegate to be called when the handler is finished
            handler = the request handler to start in a fiber

        In:
            - No other handler must have been assigned already.

    ***************************************************************************/

    public void start ( RequestId id, void[] context_blob, void[] working_blob,
        HandlerFinishedDg finished_dg, SingleNodeHandler handler )
    in
    {
        assert(!this.handler.active);
    }
    body
    {
        this.setupRequest(id, context_blob, working_blob, finished_dg);
        this.handler.single_node = handler;
        this.fiber.start();
    }

    /***************************************************************************

        Starts the request handler for one node as a part of an all-nodes
        request.

        Params:
            id = the request id
            context_blob = the opaque data stored as the request's context. This
                data is shared between all RoCs (sliced)
            working_blob = the opaque data owned by this RoC (copied internally)
            finished_dg = delegate to be called when the handler is finished
            handler    = the request handler to start in a fiber
            connection = the connection with which handler should communicate

        In:
            - No other handler must have been assigned already.

    ***************************************************************************/

    public void start ( RequestId id, void[] context_blob, void[] working_blob,
        HandlerFinishedDg finished_dg, AllNodesHandler handler, Connection connection )
    in
    {
        assert(!this.handler.active);
    }
    body
    {
        this.setupRequest(id, context_blob, working_blob, finished_dg);
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
            working_blob = the opaque data owned by this RoC (copied internally)
            finished_dg = delegate to be called when the handler is finished
            handler = the request handler to start in a fiber

        In:
            - No other handler must have been assigned already.

    **************************************************************************/

    public void start ( RequestId id, void[] context_blob, void[] working_blob,
        HandlerFinishedDg finished_dg, RoundRobinHandler handler )
    in
    {
        assert(!this.handler.active);
    }
    body
    {
        this.setupRequest(id, context_blob, working_blob, finished_dg);
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

        /*final*/ switch (this.handler.active)
        {
            case handler.active.single_node:
                handler.single_node()(&this.useNode, this.request_context,
                    this.working_data);
                break;

            case handler.active.all_nodes:
                auto all_nodes = handler.all_nodes;
                this.connection = all_nodes.connection;
                scope ed = this.new EventDispatcherAllNodes(this.request_id, all_nodes.connection);
                all_nodes.dg(ed, this.request_context, this.working_data);

/+
                // Call the request handler repeatedly as long as it returns
                // true, indicating it wants to be restarted.
                while (all_nodes.dg(this, ed, this.request_context,
                    this.working_data))
                {
                    // If the connection is down, register a fiber resuming
                    // delegate with the connection that will be called when it
                    // is available again, and suspend the fiber.
                    if (
                        all_nodes.connection.registerConnectedNotification({
                            this.resumeFiber_(fiber.Message.init);
                        })
                    )
                    {
                        // FIXME: we can't simply suspend the fiber here, as it
                        // may also be resumed by non-I/O events (a request
                        // controller, for example). It seems that this situation
                        // (restarting a request on reconnection) must be handled
                        // directly by the request handler, which should catch
                        // exceptions and then suspend the fiber and check for a
                        // special (new) resume code.
                        this.suspendFiber();
                    }
                }
+/
                break;

            case handler.active.round_robin:
                scope ed = this.new EventDispatcher;
                scope edrr = new EventDispatcherRoundRobin(ed);
                handler.round_robin()(edrr, this.request_context,
                    this.working_data);
                break;

            default: case handler.active.none:
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

    override public void getPayloadForSending ( void delegate ( void[][] payload ) send )
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

    public bool connectedTo ( IPAddress node_address )
    {
        return this.connection
            ? this.connection.remote_address == node_address
            : false;
    }

    /***************************************************************************

        Populates this instance with request parameters.

        Params:
            request = the request that called this.start().
            context_blob = the opaque data stored as the request's context. This
                data is shared between all RoCs (sliced)
            working_blob = the opaque data owned by this RoC (copied internally)
            finished_dg = delegate to be called when the handler is finished

    ***************************************************************************/

    private void setupRequest ( RequestId id, void[] context_blob,
        void[] working_blob, HandlerFinishedDg finished_dg )
    {
        this.request_id = id;
        this.request_context = context_blob;
        this.finished_dg = finished_dg;

        this.working_data.length = working_blob.length;
        enableStomping(this.working_data);
        this.working_data[] = working_blob[];
    }

    /***************************************************************************

        Resets this instance after use. Called from runHandler(), when the fiber
        is about to exit.

    ***************************************************************************/

    private void reset ( )
    {
        this.handler = this.handler.init;
        this.connection = null;
        this.working_data = null;
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

    private bool useNode ( IPAddress node_address,
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
