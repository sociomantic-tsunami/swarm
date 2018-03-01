/*******************************************************************************

    Fiber-based node connection handler class

    The node connection handler class is designed to be managed by an instance
    of SelectListener, which keeps a pool of connection handlers, listens
    for incoming connections, then assigns a new connection to a connection
    handler in the pool.

    The connection handler class handles reading the command code from the
    client, checking whether it is a valid command, then selecting from a set of
    request handler objects and assigning the request to the appropriate
    handler. Once a command has finished processing, the connection handler
    tries to read the next command from the client.

    copyright: Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.neo.node.ConnectionHandler;

/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.transition;
import ocean.net.server.connection.IConnectionHandler;
import ocean.sys.socket.AddressIPSocket;
import ocean.util.log.Logger;

/*******************************************************************************

    Static module logger

*******************************************************************************/

private Logger log;
static this ( )
{
    log = Log.lookup("swarm.neo.node.ConnectionHandler");
}

/******************************************************************************/

class ConnectionHandler : IConnectionHandler
{
    import swarm.neo.node.Connection;
    import swarm.neo.node.RequestOnConn;
    import swarm.neo.node.IRequestHandler;
    import swarm.neo.request.Command;

    import ocean.io.select.EpollSelectDispatcher;
    import ocean.time.StopWatch;

    import ClassicSwarm =
        swarm.node.connection.ConnectionHandler: ConnectionSetupParams;

    import ocean.transition;

    /// Map of request handling info indexed by command code.
    public struct RequestMap
    {
        import swarm.node.request.RequestStats;

        /***********************************************************************

            Definition of a command handler function. It is called when a new
            incoming request is handled and runs in its own fiber (the fiber
            owned by the passed RequestOnConn instance).

            Params:
                shared_resources = an opaque object containing resources owned
                    by the node which are required by the request
                connection = manages the connection socket I/O and the fiber
                cmdver = the command version
                msg_payload = the payload of the first message for the request

        ***********************************************************************/

        public alias void function ( Object shared_resources,
            RequestOnConn connection, Command.Version cmdver,
            Const!(void)[] msg_payload ) Handler;

        /// Details stored in map about a single request.
        public struct RequestInfo
        {
            /// The name of the request, used for stats tracking.
            istring name;

            /// The ClassInfo of the request handler class that is newed when
            /// handling a request of this type.
            ClassInfo class_info;

            /// The request handler function, called when a request of this type
            /// is initiated.
            /// Note: this field is only used when a request is set up with the
            /// deprecated add() methods.
            Handler handler;

            /// Indicates whether timing stats should be gathered about the
            /// request.
            bool timing;
        }

        /// Map of request info by command code.
        // (When the deprecated add method is removed, this field can be too.)
        private RequestInfo[Command.Code] map;

        /// Map of request info by request/version code.
        private RequestInfo[Command] request_info;

        /// Set of supported request codes.
        private bool[Command.Code] supported_requests;

        /***********************************************************************

            Adds a request to the map.

            Params:
                code = command code to initiate request
                name = name of request
                handler = function called to handle this request type
                timing = if true, timing stats about request of this type are
                    tracked

        ***********************************************************************/

        deprecated("Use the other version of `add` that provides info for "
            "specific request versions")
        public void add ( Command.Code code, cstring name, Handler handler,
            bool timing = true )
        {
            RequestInfo ri;
            ri.name = idup(name);
            ri.handler = handler;
            ri.timing = timing;
            this.map[code] = ri;
            this.supported_requests[code] = true;
        }

        /***********************************************************************

            Adds a request/version to the map.

            Params:
                command = command (request/version code) to initiate request
                name = name of request
                class_info = class that handles this request type
                timing = if true, timing stats about request of this type are
                    tracked

        ***********************************************************************/

        public void add ( Command command, cstring name, ClassInfo class_info,
            bool timing = true )
        in
        {
            assert((command.code in this.map) is null,
                "Either add a single handler for all versions of a request or "
                ~ "separate handlers for each version");
            assert(name.length > 0);
            assert(class_info !is null);
        }
        body
        {
            RequestInfo ri;
            ri.name = idup(name);
            ri.class_info = class_info;
            ri.timing = timing;
            this.request_info[command] = ri;
            this.supported_requests[command.code] = true;
        }

        /***********************************************************************

            Adds an unnamed request to the map. (This method exists in order to
            mimic the API of an associative array, for compatibility with old
            code.)

            Params:
                handler = function called to handle this request type
                code = command code to initiate request

        ***********************************************************************/

        deprecated("Use the `add` method instead, specifying a name for the request.")
        public void opIndexAssign ( Handler handler, Command.Code code )
        {
            RequestInfo ri;
            ri.handler = handler;
            ri.timing = true;
            this.map[code] = ri;
            this.supported_requests[code] = true;
        }

        /***********************************************************************

            Sets up stats tracking for all requests in the map.

            Params:
                request_stats = neo request stats tracking object

        ***********************************************************************/

        public void initStats ( RequestStats request_stats )
        {
            foreach ( code, rq; this.map )
                if ( rq.name.length > 0 )
                    request_stats.init(rq.name, rq.timing);

            foreach ( command, rq; this.request_info )
                if ( !(rq.name in request_stats.request_stats ) )
                    request_stats.init(rq.name, rq.timing);
        }
    }

    /// Alias to old name.
    deprecated("Use the `RequestMap` struct instead.")
    public alias RequestMap CmdHandlers;

    /***************************************************************************

        Type of a delegate that provides a scope-allocated request resource
        acquirer, via the provided delegate, for use in a request handler.

        Params:
            handle_request_dg = delegate that receives a resources acquirer and
                initiates handling of a request

    ***************************************************************************/

    public alias void delegate (
        void delegate ( Object resource_acquirer ) handle_request_dg )
        GetResourceAcquirerDg;

    /***************************************************************************

        Connection handler shared parameters class. Passed to the constructor.

    ***************************************************************************/

    public static class SharedParams
    {
        import ocean.io.select.EpollSelectDispatcher;

        import swarm.neo.authentication.CredentialsFile;
        import swarm.neo.authentication.HmacDef: Key;
        import swarm.node.model.INodeInfo;

        /***********************************************************************

            Map of command codes -> request handling info.

        ***********************************************************************/

        public RequestMap requests;

        /// Alias to old name.
        deprecated("Use the `requests` member instead.")
        public alias requests cmd_handlers;

        /***********************************************************************

            Epoll instance used by the node.

        ***********************************************************************/

        public EpollSelectDispatcher epoll;

        /***********************************************************************

            Pointer to the map of auth names -> keys.

        ***********************************************************************/

        public Const!(Key[istring])* credentials;

        /***********************************************************************

            Pool for `Request` objects, shared across all connections.

        ***********************************************************************/

        public Connection.RequestPool request_pool;

        /***********************************************************************

            Global resumer to resume yielded `RequestOnConn`s

        ***********************************************************************/

        public Connection.YieldedRequestOnConns yielded_rqonconns;

        /***********************************************************************

            Opaque shared resources instance passed to the request handlers.

            When the deprecated methods of RequestMap are removed, this instance
            can also be removed. It should be no longer needed. (The
            get_resource_acquirer delegate plays the same role.)

        ***********************************************************************/

        public Object shared_resources;

        /***********************************************************************

            Delegate that provides a scope-allocated request resource acquirer
            for use in request handlers.

        ***********************************************************************/

        public GetResourceAcquirerDg get_resource_acquirer;

        /***********************************************************************

            Flag controlling whether Nagle's algorithm is disabled (true) or
            left enabled (false) on the underlying socket.

            (The no-delay option is not generally suited to live servers, where
            efficient packing of packets is desired, but can be useful for
            low-bandwidth test setups.)

        ***********************************************************************/

        public bool no_delay;

        /***********************************************************************

            Node info interface. Used to get access to the neo request stats
            tracker.

        ***********************************************************************/

        public INodeInfo node_info;

        /***********************************************************************

            Constructor.

            Note that `unix_socket_path.length` needs to be less than
            `UNIX_PATH_MAX`, a constant defined in `ocean.stdc.posix.sys.un`.

            Params:
                epoll = epoll dispatcher used by the node
                shared_resources = global resources shared by all request
                    handlers
                requests = map of command code -> request handling info
                no_delay = if false, data written to the socket will be buffered
                    and sent according to Nagle's algorithm. If true, no
                    buffering will occur. (The no-delay option is not generally
                    suited to live servers, where efficient packing of packets
                    is desired, but can be useful for low-bandwidth test setups.)
                credentials = map of auth names -> keys
                node_info = node informational interface
                get_resource_acquirer = delegate that provides a scope-allocated
                    request resource acquirer for use in request handlers

        ***********************************************************************/

        public this ( EpollSelectDispatcher epoll, Object shared_resources,
            RequestMap requests, bool no_delay,
            ref Const!(Key[istring]) credentials, INodeInfo node_info,
            GetResourceAcquirerDg get_resource_acquirer )
        {
            assert(requests.supported_requests.length > 0);

            this.epoll = epoll;
            this.shared_resources = shared_resources;
            this.request_pool = new Connection.RequestPool;
            this.yielded_rqonconns = new Connection.YieldedRequestOnConns;
            epoll.register(this.yielded_rqonconns);
            this.requests = requests;
            this.requests.map.rehash;
            this.no_delay = no_delay;
            this.credentials = &credentials;
            this.node_info = node_info;
            this.get_resource_acquirer = get_resource_acquirer;
        }
    }

    /***************************************************************************

        Low-level I/O handler and message parser.

    ***************************************************************************/

    private Connection connection;

    /***************************************************************************

        Parameters shared across all instances of this class.

    ***************************************************************************/

    private SharedParams shared_params;

    /***************************************************************************

        Returns this instance to the `SelectListener` pool of connection
        handlers.

    ***************************************************************************/

    private FinalizeDg return_to_pool;

    /***************************************************************************

        Constructor.

        Params:
            return_to_pool = delegate to be called when this instance should be
                recycled to the `SelectListener`'s pool of connection handlers
            shared_params = parameters shared across all instances of this class

    ***************************************************************************/

    public this ( FinalizeDg return_to_pool, SharedParams shared_params )
    {
        auto socket = new AddressIPSocket!();
        super(socket, null, null);

        this.connection = new Connection(
            *shared_params.credentials, socket, shared_params.epoll,
            &this.handleRequest, &this.whenConnectionClosed,
            shared_params.request_pool, shared_params.yielded_rqonconns,
            shared_params.no_delay
        );
        this.return_to_pool = return_to_pool;
        this.shared_params = shared_params;
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

        Returns:
            the number of bytes sent over the connection since the last call to
            this method

    ***************************************************************************/

    public ulong bytes_sent ( )
    {
        return this.connection.getIOStats(true, true).socket.total;
    }

    /***************************************************************************

        Returns:
            the number of bytes received over the connection since the last call
            to this method

    ***************************************************************************/

    public ulong bytes_received ( )
    {
        return this.connection.getIOStats(false, true).socket.total;
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

    protected void handleRequest ( RequestOnConn connection, Const!(void)[] init_payload = null )
    {
        if (init_payload.length >= Command.sizeof)
        {
            auto command = *this.connection.message_parser.getValue!(Command)(init_payload);

            // deprecated handlers without version handling
            if (auto rq = command.code in this.shared_params.requests.map)
            {
                this.handleRequest(*rq, connection,
                    {
                        (*rq.handler)(this.shared_params.shared_resources,
                            connection, command.ver, init_payload);
                    });
            }
            // Supported request codes.
            else if (command.code in
                this.shared_params.requests.supported_requests)
            {
                // Supported version codes.
                if (auto rq = command in this.shared_params.requests.request_info)
                {
                    // TODO: when the old deprecated handlers are removed, this
                    // logic can be moved into handleRequest.
                    this.handleRequest(*rq, connection,
                        {
                            bool acquired;
                            this.shared_params.get_resource_acquirer(
                                ( Object request_resources )
                                {
                                    acquired = true;
                                    auto rq_handler =
                                        this.emplace!(IRequestHandler)
                                        (connection.emplace_buf, rq.class_info);
                                    rq_handler.initialise(connection,
                                        request_resources);
                                    rq_handler.preSupportedCodeSent(
                                        init_payload);
                                    this.sendSupportedStatus(connection,
                                        SupportedStatus.RequestSupported);
                                    rq_handler.postSupportedCodeSent();
                                }
                            );
                            // TODO: this check can be removed when the old
                            // deprecated handlers are removed.
                            assert(acquired);
                        });
                }
                // Unsupported version codes.
                else
                {
                    this.sendSupportedStatus(connection,
                        SupportedStatus.RequestVersionNotSupported);
                }
            }
            // Unsupported request codes.
            else
            {
                this.sendSupportedStatus(connection,
                    SupportedStatus.RequestNotSupported);
            }
        }
        else
        {
            throw connection.event_dispatcher.shutdownWithProtocolError(
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

        Called when an incoming supported request is to be handled. Runs in the
        fiber of `connection`.

        Params:
            rq = request info struct (including handler function)
            connection = manages the connection socket I/O and the fiber

    ***************************************************************************/

    private void handleRequest ( RequestMap.RequestInfo rq,
        RequestOnConn connection, void delegate ( ) handle_request )
    {
        StopWatch timer;

        if ( rq.name )
        {
            this.shared_params.node_info.neo_request_stats
                .started(rq.name);

            if ( rq.timing )
                timer.start();
        }

        scope ( exit )
        {
            if ( rq.name )
            {
                if ( rq.timing )
                    this.shared_params.node_info.neo_request_stats
                        .finished(rq.name, timer.microsec);
                else
                    this.shared_params.node_info.neo_request_stats
                        .finished(rq.name);
            }
        }

        try
        {
            handle_request();
        }
        catch ( Exception e )
        {
            log.error("{}:{}: Exception thrown from request handler: {} @ {}:{}",
                this.connection.connected_client, rq.name,
                getMsg(e), e.file, e.line);
            throw e;
        }
    }

    /***************************************************************************

        Sends a supported status code to the client.

        Params:
            connection = connection to send the status code to
            code = supported status code to send

    ***************************************************************************/

    private void sendSupportedStatus ( RequestOnConn connection,
        SupportedStatus code )
    {
        auto ed = connection.event_dispatcher;
        ed.send(
            ( ed.Payload payload )
            {
                payload.add(code);
            }
        );
    }

    /***************************************************************************

        Emplaces an instance of the specified class into the provided buffer.

        Note that the class indicated by `ci` must fit the following criteria:
            * Must have no constructors. `emplace()` does not call a ctor on the
              created instance.
            * Must not have a destructor. An emplaced instance is not registered
              with the GC in the normal way, and will not be destructed like a
              normal object.

        Params:
            T = type to return. The class described by the provided ClassInfo
                must derive from T
            buf = buffer in which to instantiate the object
            ci = ClassInfo of class to instantiate

        Returns:
            an instance of the class specified by `ci`, emplaced in the provided
            buffer and cast to `T`

    ***************************************************************************/

    private T emplace ( T ) ( ref void[] buf, ClassInfo ci )
    {
        assert(!(ci.flags & 8) && ci.defaultConstructor is null);
        assert(ci.destructor is null);

        version (D_Version2)
        {
            auto initializer = ci.initializer();
        }
        else
        {
            auto initializer = ci.init;
        }

        // Allocate space
        buf.length = initializer.length;
        enableStomping(buf);

        // Initialize it
        buf[] = initializer[];

        // Cast to T (and check that the cast succeeded)
        auto t_instance = cast(T)cast(Object)buf.ptr;
        assert(t_instance !is null);
        return t_instance;
    }
}

version ( UnitTest )
{
    import swarm.node.request.RequestStats;
    import swarm.neo.request.Command;
}

// Check that initialising stats for two versions of a request works. (Stats for
// both versions will be tracked under the same request name.)
unittest
{
    class Rq1_v0 { }
    class Rq1_v1 { }

    ConnectionHandler.RequestMap map;
    auto rq1_v0 = Command(1, 0);
    auto rq1_v1 = Command(1, 1);

    map.add(rq1_v0, "Request1", Rq1_v0.classinfo);
    map.add(rq1_v1, "Request1", Rq1_v1.classinfo);

    map.initStats(new RequestStats);
}
