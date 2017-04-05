/*******************************************************************************

    Client core mixin template. Provides the basic components required by a neo
    client:
        * A connection set.
        * A constructor which accepts the auth details and a connection
          notifier, passing these through to the connection set.
        * Public methods to add nodes and check whether all nodes are connected.
        * Private methods to assign and control requests.

    Copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.client.mixins.ClientCore;

/// ditto
template ClientCore ( )
{
    import ocean.transition;
    import ocean.core.Enforce;

    import swarm.neo.IPAddress;

    import swarm.neo.client.IRequestSet : IRequestController;
    import swarm.neo.client.RequestSet;
    import swarm.neo.client.ConnectionSet;
    import swarm.neo.client.RequestOnConn;

    import swarm.neo.protocol.Message: RequestId;

    import swarm.neo.authentication.Credentials;
    import swarm.neo.authentication.HmacDef : key_length;

    import swarm.client.helper.NodesConfigReader;

    /***************************************************************************

        Convenience alias for the connection notification union.

    ***************************************************************************/

    public alias ConnectionSet.ConnNotification ConnNotification;

    /***************************************************************************

        Convenience alias for the connection notifier.

    ***************************************************************************/

    public alias ConnectionSet.ConnectionNotifier ConnectionNotifier;

    /***************************************************************************

        Set of connections to nodes. (Owns the set of requests.)

    ***************************************************************************/

    private ConnectionSet connections;

    /***************************************************************************

        Object for request to acquire needed resources from.

    ***************************************************************************/

    private Object request_resources;

    /***************************************************************************

        Constructor (private, so that only the client class where this template
        is mixed-in can construct an instance).

        Params:
            auth_name = name of the client, for authorisation
            auth_key = key of the client, for authorisation
            conn_notifier = delegate which is called when a connection
                attempt succeeds or fails (including when a connection is
                re-established). Of type:
                void delegate ( IPAddress node_address, Exception e )
            request_resources = object to acquire resources from

    ***************************************************************************/

    private this ( cstring auth_name, in ubyte[] auth_key,
        ConnectionNotifier conn_notifier, Object request_resources = null )
    {
        assert(auth_key.length == key_length);

        Credentials cred;
        cred.name = auth_name.dup;
        cred.key.content[] = auth_key[];
        this.connections = new ConnectionSet(cred, this.outer.epoll,
            conn_notifier);
        this.request_resources = request_resources;
    }

    /***************************************************************************

        Adds a node to the connection set and initiates connection
        establishment.

        Params:
            host = address of node to connect to
            port = port to connect to

    ***************************************************************************/

    public void addNode ( cstring host, ushort port )
    {
        IPAddress ip;
        auto addr_ok = ip.setAddress(host);
        enforce(addr_ok, cast(istring)("Invalid address: " ~ host));
        ip.port = port;
        this.connections.start(ip);
    }

    /***************************************************************************

        Adds node connections to the registry, read from a config file. The
        nodes are specified in the config file as follows:

        ---
            192.168.2.128:30010
            192.168.2.128:30011
        ---

        Params:
            file = name of config file to read

    ***************************************************************************/

    public void addNodes ( cstring file )
    {
        foreach ( node; NodesConfigReader(file) )
        {
            this.addNode(node.Address, node.Port);
        }
    }

    /***************************************************************************

        Stats/information getter interface. May be newed on the stack (see usage
        example, below).

    ***************************************************************************/

    public class Stats
    {
        import swarm.neo.protocol.socket.IOStats;
        import swarm.neo.util.TreeQueue : TreeQueueStats;

        /***********************************************************************

            Returns:
                the number of active requests

        ***********************************************************************/

        public size_t num_active_requests ( )
        {
            return this.outer.connections.request_set.num_active;
        }

        /***********************************************************************

            Returns:
                the maximum number of active requests allowed at one time

        ***********************************************************************/

        public size_t max_active_requests ( )
        {
            return this.outer.connections.request_set.max_requests;
        }

        /***********************************************************************

            Returns:
                the number of currently active requests as a fraction (0..1) of
                the maximum number possible

        ***********************************************************************/

        public double active_requests_fraction ( )
        {
            return cast(double)this.outer.connections.request_set.num_active /
                cast(double)this.outer.connections.request_set.max_requests;
        }

        /***********************************************************************

            Returns:
                the number of nodes which have been registered with the client
                via addNode() or addNodes()

        ***********************************************************************/

        public size_t num_registered_nodes ( )
        {
            return this.outer.connections.length;
        }

        /***********************************************************************

            Returns:
                the number of registered nodes to which the client is in the
                state of establishing a connection *for the first time*

        ***********************************************************************/

        public size_t num_initializing_nodes ( )
        {
            return this.outer.connections.num_initializing_nodes;
        }

        /***********************************************************************

            Returns:
                the number of nodes to which the client is in the state of
                establishing a connection *for the first time* as a fraction
                (0..1) of the number of registered nodes

        ***********************************************************************/

        public double initializing_nodes_fraction ( )
        {
            return cast(double)this.outer.connections.num_initializing_nodes /
                cast(double)this.outer.connections.length;
        }

        /***********************************************************************

            Returns:
                the number of registered nodes to which the client has an
                established connection

        ***********************************************************************/

        public size_t num_connected_nodes ( )
        {
            return this.outer.connections.num_connected_nodes;
        }

        /***********************************************************************

            Returns:
                true if a connection is established to all registered nodes

        ***********************************************************************/

        public bool all_nodes_connected ( )
        {
            return this.outer.connections.num_connected_nodes ==
                this.outer.connections.length;
        }

        /***********************************************************************

            Returns:
                the number of nodes to which the client has an established
                connection as a fraction (0..1) of the number of registered
                nodes

        ***********************************************************************/

        public double connected_nodes_fraction ( )
        {
            return cast(double)this.outer.connections.num_connected_nodes /
                cast(double)this.outer.connections.length;
        }

        /***********************************************************************

            Connection I/O stats fruct.

        ***********************************************************************/

        public struct ConnIOStatsFruct
        {
            /// Connection set of the client.
            private ConnectionSet connections;

            /*******************************************************************

                foreach implementation over the I/O stats for the connections.

            *******************************************************************/

            public int opApply (
                int delegate ( ref IOStats sender, ref IOStats receiver ) dg )
            {
                int res;
                foreach ( conn; this.connections )
                {
                    auto sender_stats = conn.getIOStats(true);
                    auto receiver_stats = conn.getIOStats(false);
                    res = dg(sender_stats, receiver_stats);
                    if ( res )
                        break;
                }
                return res;
            }
        }

        /***********************************************************************

            Returns:
                a foreach struct over the I/O stats for the connections

        ***********************************************************************/

        public ConnIOStatsFruct connection_io ( )
        {
            return ConnIOStatsFruct(this.outer.connections);
        }

        /***********************************************************************

            Connection send queue stats fruct.

        ***********************************************************************/

        public struct ConnSendQueueStatsFruct
        {
            /// Connection set of the client.
            private ConnectionSet connections;

            /*******************************************************************

                foreach implementation over the send queue stats for the
                connections.

            *******************************************************************/

            public int opApply ( int delegate ( ref TreeQueueStats ) dg )
            {
                int res;
                foreach ( conn; this.connections )
                {
                    auto queue_stats = conn.getSendQueueStats();
                    res = dg(queue_stats);
                    if ( res )
                        break;
                }
                return res;
            }
        }

        /***********************************************************************

            Returns:
                a foreach struct over the stats for the connections' send queues

        ***********************************************************************/

        public ConnSendQueueStatsFruct connection_send_queue ( )
        {
            return ConnSendQueueStatsFruct(this.outer.connections);
        }
    }

    ///
    unittest
    {
        void printClientStats ( typeof(this) client )
        {
            scope stats = client.new Stats;
            Stdout.formatln("{} requests currently active",
                stats.num_active_requests);
        }
    }

    version ( UnitTest )
    {
        import ocean.io.Stdout;
    }

    /***************************************************************************

        Template for a per-request stats/information getter interface. May be
        newed on the stack.

        Concrete clients that want to expose per-request stats should provide a
        public alias instantiating this template (see unit test at end of
        module).

        Params:
            Requests = tuple of request names. All elements must be implicitly
                castable to istring

    ***************************************************************************/

    private class RequestStatsTemplate ( Requests ... )
    {
        import swarm.neo.client.requests.Stats;

        // Instantiating this template with 0 elements doesn't make any sense.
        static assert(Requests.length > 0);

        /// typeof(this) convenience alias
        mixin TypeofThis;

        /***********************************************************************

            Gets the stats for the request with the specified name.

            Note that it is assumed that the symbol `Internals.<name>` can be
            resolved in the outer class (the client's Neo object) to the
            internal request wrapper struct for the appropriate request.

            Params:
                name = name of request to get stats for

            Returns:
                stats getter instance (IRequestStats.RequestStats) for the
                specified request

        ***********************************************************************/

        public IRequestStats.RequestStats request ( istring name ) ( )
        {
            mixin("alias Internals." ~ name ~ " Request;");
            return this.outer.connections.request_set.stats.requestStats(
                &Request.all_finished_notifier);
        }

        /***********************************************************************

            Foreach struct ("fruct") providing opApply over stats getter
            instances for all requests specified in Requests.

        ***********************************************************************/

        private struct RequestStatsFruct
        {
            /// Reference to outer object.
            private This outer;

            /*******************************************************************

                Foreach iterator over request names and stats getter instances
                for all requests specified in Requests.

            *******************************************************************/

            public int opApply ( int delegate ( ref istring request_name,
                ref IRequestStats.RequestStats request_stats ) dg )
            {
                int res;
                foreach ( rq_name; Requests )
                {
                    static assert(is(typeof(rq_name) : istring));

                    auto slice = rq_name[];
                    auto stats = this.outer.request!(rq_name)();
                    res = dg(slice, stats);
                    if ( res )
                        break;
                }
                return res;
            }
        }

        /***********************************************************************

            Returns:
                iterator over request names and stats getter instances for all
                requests specified in Requests

        ***********************************************************************/

        public RequestStatsFruct allRequests ( )
        {
            return RequestStatsFruct(this);
        }

        /***********************************************************************

            Resets all request stats to 0. (Call this after logging stats.)

        ***********************************************************************/

        public void clear ( )
        {
            this.outer.connections.request_set.stats.clear();
        }
    }

    /***************************************************************************

        Shuts down all connections, closing the sockets and freeing the fds.

    ***************************************************************************/

    public void shutdown ( istring file = __FILE__, typeof(__LINE__) line = __LINE__ )
    {
        this.connections.stopAll(file, line);
    }

    /***************************************************************************

        Note: currently unimplemented.

        Aborts all requests. This will be useful for an application which
        wants to shut down while it still has requests pending. Aborting all
        requests should cause their finished notifications to be fired,
        giving the user access to the request context, which can then be
        dumped to disk.

    ***************************************************************************/

    public void abortAllRequests ( )
    {
        // TODO
    }

    /***************************************************************************

        Gets access to a controller for the specified request. If the
        request is still active, the controller is passed to the provided
        delegate for use.

        Important usage notes:
            1. The controller is newed on the stack. This means that user
               code should never store references to it -- it must only be
               used within the scope of the delegate.
            2. As the id which identifies the request is only known at run-
               time, it is not possible to statically enforce that the
               specified ControllerInterface type matches the request. This
               is asserted at run-time, though (see
               RequestSet.getRequestController()).

        Params:
            Request = type of the wrapper struct of the request to be controlled
            ControllerInterface = type of the controller interface (should
                be inferred by the compiler)
            id = id of request to get a controller for (the return value of
                the method which assigned your request)
            dg = delegate which is called with the controller, if the
                request is still active

        Returns:
            false if the specified request no longer exists

    ***************************************************************************/

    private bool controlImpl ( Request, ControllerInterface ) ( RequestId id,
        void delegate ( ControllerInterface ) dg )
    {
        if ( auto rq_control =
            this.connections.request_set.getRequestController(id,
                &Request.all_finished_notifier) )
        {
            scope controller = new Request.Controller(rq_control);
            dg(controller);

            return true;
        }

        return false;
    }

    /***************************************************************************

        Assigns a request of the specified type, with the specified
        arguments.

        Params:
            R = type of internal namespace request struct
            P = type of public request parameters struct
            params = request parameters struct

        Returns:
            id of newly assigned request

    ***************************************************************************/

    private RequestId assign ( R, P ) ( P params )
    {
        static assert(is(P == R.UserSpecifiedParams));

        R.Context context;
        context.user_params = params;
        context.request_resources.set(this.request_resources);

        static if ( R.request_type == R.request_type.SingleNode )
        {
            enforce(this.connections.length,
                "Cannot assign a single-node request when there are no nodes registered");

            return this.connections.request_set.startSingleNode(&R.handler,
                &R.all_finished_notifier, context, R.Working.init);
        }
        else static if ( R.request_type == R.request_type.RoundRobin )
        {
            enforce(this.connections.length,
                "Cannot assign a round-robin request when there are no nodes registered");

            return this.connections.request_set.startRoundRobin(&R.handler,
                &R.all_finished_notifier, context, R.Working.init);
        }
        else static if ( R.request_type == R.request_type.AllNodes )
        {
            return this.connections.request_set.startAllNodes(&R.handler,
                &R.all_finished_notifier, context, R.Working.init);
        }
        else
        {
            static assert(false, "Invalid request type");
        }
    }
}

/*******************************************************************************

    Fake client which test instantiating the ClientCore and
    ClientCore.RequestStatsTemplate templates.

*******************************************************************************/

version ( UnitTest )
{
    import ocean.io.Stdout;

    class FakeClient
    {
        import ocean.io.select.EpollSelectDispatcher;
        import swarm.neo.client.IRequestSet : IRequestWorkingData;

        // Required by ClientCore.
        private EpollSelectDispatcher epoll;
        public Neo neo;

        class Neo
        {
            // Some imaginary requests, for the sake of testing
            // ClientCore.RequestStatsTemplate
            struct Internals
            {
                struct Get
                {
                    // Required by ClientCore.RequestStatsTemplate
                    static:
                    void all_finished_notifier ( void[], IRequestWorkingData ) { }
                }

                struct Put
                {
                    // Required by ClientCore.RequestStatsTemplate
                    static:
                    void all_finished_notifier ( void[], IRequestWorkingData ) { }
                }
            }

            // Instantiation of ClientCore.
            mixin ClientCore!();

            // Instantiation of RequestStatsTemplate for an imaginary client
            // which has requests named Put and Get.
            alias RequestStatsTemplate!("Put", "Get") RequestStats;
        }
    }
}

/*******************************************************************************

    Test for using the per-request stats of the fake client.

*******************************************************************************/

unittest
{
    void printClientStats ( FakeClient client )
    {
        scope rq_stats = client.neo.new RequestStats;

        foreach ( rq, stats; rq_stats.allRequests() )
            Stdout.formatln("{} stats: {} finished in {} microseconds mean",
                rq, stats.count, stats.mean_handled_time_micros);
    }
}
