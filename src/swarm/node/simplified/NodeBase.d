/*******************************************************************************

    Swarm node abstract base class.

    Base class for a swarm node with the following features:
        * An optional SelectListener which handles incoming legacy protocol
          connections.
        * An optional SelectListener which handles incoming neo protocol
          connections.
        * An optional SelectListener which handles incoming unix socket
          connections.
        * Stats trackers/getters for I/O operations, connections, requests, and
          record actions.
        * Methods to register the listeners with epoll, shut down the listeners,
          and shut down the node's internals.
        * A method to log all internal stats to a logger.

    Notes:
        * A reference to NodeBase is passed to all connection handlers that it
          owns, allowing them to acces global / shared methods and data.
        * This class is deliberately templateless to simplify passing references
          to it to other classes. (If NodeBase were a template, other classes
          that needed to refer to it would also be forced to be templates.)
        * The legacy listener must be passed to the constructor as an abstract
          ISelectListener instance. This is because the legacy connection
          handler is a template, thus creating the legacy listener directly
          inside NodeBase would entail a template argument. The typical usage is
          to derive from swarm.node.simplified.NodeTemplate (which derives from
          NodeBase), specifying the type of your legacy connection handler as
          its template argument.

    TODO: this module is a replacement of the deprecated
    swarm.node.model.Node : INodeBase. The difference is that this class melds in all neo
    functionality. When the deprecated module is removed, this module may be
    moved into its place.

    copyright:
        Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.node.simplified.NodeBase;

import ocean.transition;

/// ditto
public class NodeBase
{
    import swarm.Const : NodeItem;
    import swarm.neo.AddrPort;
    import swarm.neo.authentication.NodeCredentials;
    import swarm.neo.node.RequestOnConn;
    import swarm.neo.request.Command;
    import swarm.neo.authentication.CredentialsFile;
    import swarm.neo.authentication.HmacDef: Key;
    import swarm.neo.node.Connection;
    import swarm.node.model.RecordActionCounters;
    import swarm.node.request.RequestStats;
    import swarm.node.simplified.NeoConnectionHandler;

    import ocean.core.Enforce;
    import ocean.io.select.EpollSelectDispatcher;
    import ocean.io.select.client.model.ISelectClient : IAdvancedSelectClient;
    import ocean.net.server.SelectListener;
    import ocean.net.server.connection.IConnectionHandler;
    import ocean.net.server.connection.IConnectionHandlerInfo;
    import ocean.net.server.unix.UnixListener;
    import ocean.net.server.unix.UnixConnectionHandler;
    import ocean.sys.socket.AddressIPSocket;
    import ocean.sys.socket.InetAddress;
    import ocean.util.container.pool.model.IAggregatePool;
    import ocean.util.log.Stats;

    /// Struct wrapping various options passed to the constructor.
    public struct Options
    {
        /// Epoll instance used by the node.
        public EpollSelectDispatcher epoll;

        /// De/activates support for the neo protocol.
        bool support_neo = true;

        /// De/activates support for the unix socket.
        bool support_unix_socket = true;

        /// IP address of listeners.
        cstring addr;

        /// Port of legacy protocol listener.
        ushort legacy_port;

        /// Port of neo protocol listener.
        ushort neo_port;

        /// Maximum number of queued incoming connections per listener.
        int backlog;

        /// Identifiers for the record action counters to create.
        istring[] record_action_counter_ids;

        /// Identifiers for the requests to track stats for.
        istring[] request_stats_ids;

        /***********************************************************************

            Definition of a command handler function. It is called when a new
            incoming request is handled and runs in its own fiber (the fiber
            owned by the passed RequestOnConn instance).

            Params:
                shared_resources = an opaque object containing resources owned
                    by the node which are required by the request
                connection   = manages the connection socket I/O and the fiber
                cmdver       = the command version
                msg_payload = the payload of the first message for the request

        ***********************************************************************/

        public alias void function ( Object shared_resources,
            RequestOnConn connection, Command.Version cmdver,
            Const!(void)[] msg_payload ) CommandHandler;

        /// Table of neo handler functions by command.
        public alias CommandHandler[Command.Code] CmdHandlers;

        /// Map of neo command codes -> handler functions.
        public CmdHandlers cmd_handlers;

        /// Opaque shared resources instance passed to the neo request handlers.
        public Object shared_resources;

        /***********************************************************************

            Flag controlling whether Nagle's algorithm is disabled (true) or
            left enabled (false) on the underlying neo protocol socket.

            (The no-delay option is not generally suited to live servers, where
            efficient packing of packets is desired, but can be useful for
            low-bandwidth test setups.)

        ***********************************************************************/

        public bool no_delay;

        /// The name of the neo credentials file to read from. If null, the
        /// `credentials_map` field must be set with a pre-defined credentials
        /// map.
        public istring credentials_filename;

        /// Map of neo auth names -> keys, only used if `credentials_filename`
        /// is null.
        public Key[istring] credentials_map;

        /// Unix domain server socket path. (If null, no unix socket will be
        /// opened.)
        public istring unix_socket_path;
    }

    /// Struct wrapping basic I/O stats.
    private struct IOStats
    {
        /// Count of bytes received.
        ulong bytes_received;

        /// Count of bytes sent.
        ulong bytes_sent;

        /***********************************************************************

            Resets all counters in this instance.

        ***********************************************************************/

        void reset ( )
        {
            *this = (*this).init;
        }
    }

    /// Class wrapping methods relating to connection pools.
    private class Connections
    {
        /***********************************************************************

            Sets the node's connection limit. The limit is set separately for
            the neo and legacy connection handlers.

            Params:
                max = maximum allowed number of connections to be handled at
                    once (per protocol -- neo/legacy)

        ***********************************************************************/

        public void limit ( uint max )
        {
            if ( this.outer.legacy_listener !is null )
                this.outer.legacy_listener.connection_limit(max);
            if ( this.outer.neo_listener !is null )
                this.outer.neo_listener.connection_limit(max);
        }

        /***********************************************************************

            Returns:
                the limit of the number of connections per protocol (i.e. the
                maximum number of connections the node can handle in parallel
                for either the legacy or the neo protocol) or 0 if limitation
                is disabled

        ***********************************************************************/

        public size_t limit ( )
        {
            if ( this.outer.legacy_listener !is null )
            {
                assert(this.outer.neo_listener is null ||
                    this.outer.legacy_listener.connection_limit ==
                    this.outer.neo_listener.connection_limit);

                return cast(size_t)this.outer.legacy_listener.connection_limit;
            }

            if ( this.outer.neo_listener !is null )
            {
                return cast(size_t)this.outer.neo_listener.connection_limit;
            }

            return 0;
        }

        /***********************************************************************

            Returns:
                the number of connections in the listener pools

        ***********************************************************************/

        public size_t num_in_pools ( )
        {
            size_t ret;
            if ( this.outer.legacy_listener !is null )
                ret += this.outer.legacy_listener.poolInfo.length();
            if ( this.outer.neo_listener !is null )
                ret += this.outer.neo_listener.poolInfo.length();

            return ret;
        }

        /***********************************************************************

            Returns:
                 the number of active connections being handled

        ***********************************************************************/

        public size_t num_open ( )
        {
            size_t ret;
            if ( this.outer.legacy_listener !is null )
                ret += this.outer.legacy_listener.poolInfo.num_busy();
            if ( this.outer.neo_listener !is null )
                ret += this.outer.neo_listener.poolInfo.num_busy();

            return ret;
        }
    }

    /// Epoll select dispatcher used by the node.
    public EpollSelectDispatcher epoll;

    /// IP / port of legacy listener.
    public NodeItem node_item;

    /// Basic I/O stats for the node (aggregate of all connections).
    public IOStats io_stats;

    /// Connection stats / limit methods.
    public Connections connections;

    /// Record actions stats tracker.
    public RecordActionCounters record_action_counters;

    /// Per-request stats tracker.
    public RequestStats request_stats;

    /// Alias for error callback.
    public alias IConnectionHandler.ErrorDg ErrorDg;

    /***************************************************************************

        User provided error callback delegate - called when an error occurs
        while executing an i/o handler. This can happen in two cases:

            1. When a client disconnects. This is usually valid, and means that
               the client doesn't need to make any further queue requests.

            2. When something seriously wrong has happened during i/o. In this
               case there's nothing we can do to rescue the command that was in
               process, but at least the node application can be notified that
               this has happened.

    ***************************************************************************/

    public ErrorDg error_dg;

    /// Neo protocol select listener alias. A reference to this instance
    /// (i.e. the NodeBase instance) is provided to the select listener to be
    /// passed on to each connection allocated.
    public alias SelectListener!(NeoConnectionHandler, NodeBase) NeoListener;

    /// Legacy protocol select listener instance.
    private ISelectListener legacy_listener;

    /// Neo protocol select listener instance.
    private ISelectListener neo_listener;

    /// Unix socket select listener instance.
    private ISelectListener unix_listener;

    /// Struct wrapping fields related to the neo protocol.
    private struct Neo
    {
        /// AddrPort that the neo protocol listener is bound to.
        public AddrPort addr_port;

        /// Map of command codes -> handler functions.
        public Options.CmdHandlers cmd_handlers;

        /// Neo credentials file.
        public Credentials credentials_file;

        /// Pointer to the map of auth names -> keys.
        public Const!(Key[istring])* credentials;

        /// Opaque shared resources instance passed to the request handlers.
        public Object shared_resources;

        /// Flag controlling whether Nagle's algorithm is disabled (true) or
        /// left enabled (false) on the underlying socket. See Options.
        public bool no_delay;

        /// Pool for `Request` objects, shared across all connections.
        public Connection.RequestPool request_pool;

        /// Global resumer to resume yielded `RequestOnConn`s
        public Connection.YieldedRequestOnConns yielded_rqonconns;
    }

    /// Neo-related fields.
    public Neo neo;

    /***************************************************************************

        Constructor.

        Note that creating a node without *any* select listener (i.e. not
        supporting the legacy, neo, or unix socket listeners) is allowed purely
        for the purpose of unittesting.

        Params:
            options = constructor options (see above)
            legacy_listener = legacy protocol select listener. If null, the
                legacy protocol is not supported. If you wish to support the
                legacy protocol, the typical usage is to derive from
                swarm.node.simplified.NodeTemplate (which derives from NodeBase)
                and specify the type of your legacy connection handler as its
                template argument
            legacy_socket = legacy protocol listener socket. Required in order
                to check the port number actually bound to. May be null, if
                    legacy_listener is null

    ***************************************************************************/

    public this ( Options options, ISelectListener legacy_listener,
        AddressIPSocket!() legacy_socket )
    {
        version ( UnitTest ) { }
        else
        {
            assert(legacy_listener !is null || options.support_neo ||
                options.support_unix_socket,
                "Cannot create a node without any select listener.");
            assert(options.epoll !is null,
                "Cannot create a node with an epoll instance.");
        }

        if ( legacy_listener !is null )
            assert(legacy_socket !is null,
                "If you want to support the legacy protocol, you must " ~
                "provide the listener socket to use.");

        this.epoll = options.epoll;
        this.node_item = NodeItem(options.addr.dup, options.legacy_port);
        this.legacy_listener = legacy_listener;

        AddressIPSocket!() neo_socket;

        // Neo protocol configuration (optional).
        if ( options.support_neo )
        {
            assert(options.cmd_handlers !is null);

            neo_socket = new AddressIPSocket!();
            InetAddress!(false) neo_addr;
            this.neo_listener = new NeoListener(
                neo_addr(options.addr, options.neo_port), neo_socket,
                this, options.backlog);

            this.neo.request_pool = new Connection.RequestPool;
            this.neo.yielded_rqonconns = new Connection.YieldedRequestOnConns;
            this.neo.shared_resources = options.shared_resources;
            this.neo.no_delay = options.no_delay;
            this.neo.cmd_handlers = options.cmd_handlers;
            this.neo.cmd_handlers = options.cmd_handlers.rehash;

            if ( options.credentials_filename )
            {
                assert(options.credentials_map is null);
                this.neo.credentials_file =
                    new Credentials(options.credentials_filename);
                this.neo.credentials = this.neo.credentials_file.credentials;
            }
            else
            {
                assert(options.credentials_map !is null);

                // Make sure the reference to the credentials map does not go out
                // of scope. (Store a copy in heap-allocated memory.)
                static struct S { Key[istring] cred; }
                auto s = new S;
                s.cred = options.credentials_map;
                this.neo.credentials = &s.cred;
            }
        }

        // Unix socket configuration (optional).
        if ( options.support_unix_socket )
        {
            if ( options.unix_socket_path.length )
            {
                BasicCommandHandler.Handler[istring] unix_socket_handlers;
                if ( this.neo.credentials_file )
                {
                    unix_socket_handlers =
                        ["update-credentials": &this.handleUpdateCredentials];
                }

                this.unix_listener = new UnixListener(
                    options.unix_socket_path, options.epoll,
                    unix_socket_handlers);
            }
        }

        this.request_stats = new RequestStats;
        this.record_action_counters = new RecordActionCounters(
            options.record_action_counter_ids);
        this.connections = new Connections;

        // Initialise requests to be stats tracked.
        foreach ( request_id; options.request_stats_ids )
            this.request_stats.init(request_id);

        // Update and store ports which sockets are bound to (if 0 was specified
        // in the options, a port will have been assigned automatically).
        if ( this.legacy_listener )
        {
            enforce(legacy_socket.updateAddress() == 0,
                "socket.updateAddress() failed!");
            this.node_item.Port = legacy_socket.port();
        }

        if ( options.support_neo )
        {
            enforce(neo_socket.updateAddress() == 0,
                "socket.updateAddress() failed!");
            this.neo.addr_port.setAddress(neo_socket.address());
            this.neo.addr_port.port(neo_socket.port());
        }
    }

    /***************************************************************************

        Unix domain socket connection handler, updates the credentials.

        Params:
            args = command arguments
            send_response = delegate to write to the client socket

    ***************************************************************************/

    private void handleUpdateCredentials ( cstring args,
        void delegate ( cstring response ) send_response )
    in
    {
        assert(this.neo.credentials_file);
    }
    body
    {
        if (args.length)
        {
            send_response("Error: No command arguments expected\n");
            return;
        }

        try
        {
            this.neo.credentials_file.update();
            send_response("Credentials updated.\n");
        }
        catch (Exception e)
        {
            send_response("Error updating credentials: ");
            send_response(getMsg(e));
            send_response("\n");
        }
    }

    /***************************************************************************

        Registers any selectables in the node (including the listener) with the
        provided epoll selector.

    ***************************************************************************/

    public void register ( )
    {
        if ( this.legacy_listener )
            this.epoll.register(this.legacy_listener);

        if ( this.neo_listener )
        {
            this.epoll.register(this.neo_listener);
            this.epoll.register(this.neo.yielded_rqonconns);
        }

        if ( this.unix_listener )
            this.epoll.register(this.unix_listener);
    }

    /***************************************************************************

        Flushes write buffers of stream connections.

    ***************************************************************************/

    public void flush ( )
    {
    }

    /***************************************************************************

        Shuts down the listener and all connections.

    ***************************************************************************/

    public void stopListener ( )
    {
        if ( this.legacy_listener )
        {
            this.epoll.unregister(this.legacy_listener);
            this.legacy_listener.shutdown;
        }

        if ( this.neo_listener )
        {
            this.epoll.unregister(this.neo.yielded_rqonconns);
            this.epoll.unregister(this.neo_listener);
            this.neo_listener.shutdown;
        }

        if ( this.unix_listener )
        {
            this.epoll.unregister(this.unix_listener);
            this.unix_listener.shutdown;
        }
    }

    /***************************************************************************

        Shuts down the node's internals.

    ***************************************************************************/

    public void shutdown ( )
    {
    }

    /***************************************************************************

        Resets the count of received / sent bytes and the record action
        counters.

    ***************************************************************************/

    public void resetCounters ( )
    {
        this.io_stats.reset();
        this.record_action_counters.reset();
        this.request_stats.resetCounters();
    }

    /***************************************************************************

        Logs the node's stats.

        Params:
            Logger = type of stats logger (templated for ease of unittesting)
            stats_log = stats logger to write to

    ***************************************************************************/

    public void logStats ( Logger = StatsLog ) ( Logger stats_log )
    {
        this.logGlobalStats(stats_log);
        this.logRequestStats(stats_log);
        this.logActionStats(stats_log);
        this.resetCounters();
    }

    /***************************************************************************

        Called upon occurrence of an i/o error. In turn calls the user provided
        error delegate, if one exists.

        Params:
            exception = exception which occurred
            event = select event during which the exception occurred

    ***************************************************************************/

    public void error ( Exception exception, IAdvancedSelectClient.Event event,
        IConnectionHandlerInfo conn )
    {
        if ( this.error_dg )
        {
            this.error_dg(exception, event, conn);
        }
    }

    /***************************************************************************

        Logs the global stats.

        Params:
            Logger = type of stats logger (templated for ease of unittesting)
            stats_log = stats logger to write to

    ***************************************************************************/

    protected void logGlobalStats ( Logger = StatsLog ) ( Logger stats_log )
    {
        struct GlobalStats
        {
            ulong bytes_sent;
            ulong bytes_received;
            size_t handling_connections;
            ubyte handling_connections_pcnt;
        }

        GlobalStats stats;
        stats.bytes_sent = this.io_stats.bytes_sent;
        stats.bytes_received = this.io_stats.bytes_received;
        stats.handling_connections = this.connections.num_open;

        if ( this.connections.limit )
            stats.handling_connections_pcnt = cast(ubyte)
                ((this.connections.num_open * 100.0f) / this.connections.limit);

        stats_log.add(stats);
    }

    /***************************************************************************

        Logs the per-action stats.

        Params:
            Logger = type of stats logger (templated for ease of unittesting)
            stats_log = stats logger to write to

    ***************************************************************************/

    protected void logActionStats ( Logger = StatsLog ) ( Logger stats_log )
    {
        foreach ( id, stats; this.record_action_counters )
        {
            stats_log.addObject!("action")(id, stats);
        }
    }

    /***************************************************************************

        Logs the per-request stats.

        Params:
            Logger = type of stats logger (templated for ease of unittesting)
            stats_log = stats logger to write to

    ***************************************************************************/

    protected void logRequestStats ( Logger = StatsLog ) ( Logger stats_log )
    {
        struct RequestStats
        {
            uint max_active;
            uint handled;
            double mean_handled_time_micros;
            ulong handled_10_micros;
            ulong handled_100_micros;
            ulong handled_1_ms;
            ulong handled_10_ms;
            ulong handled_100_ms;
            ulong handled_over_100_ms;
        }

        foreach ( id, request; this.request_stats.request_stats )
        {
            RequestStats stats;
            stats.max_active = request.max_active;
            stats.handled = request.finished;
            stats.mean_handled_time_micros = request.mean_handled_time_micros;
            stats.handled_10_micros = request.handled_10_micros;
            stats.handled_100_micros = request.handled_100_micros;
            stats.handled_1_ms = request.handled_1_ms;
            stats.handled_10_ms = request.handled_10_ms;
            stats.handled_100_ms = request.handled_100_ms;
            stats.handled_over_100_ms = request.handled_over_100_ms;

            stats_log.addObject!("request")(id, stats);
        }
    }
}

/*******************************************************************************

    Unittest helpers

*******************************************************************************/

version ( UnitTest )
{
    import ocean.core.Test;

    class TestNode : NodeBase
    {
        this ( istring[] record_action_counter_ids, istring[] request_stats_ids )
        {
            Options opt;
            opt.support_neo = false;
            opt.record_action_counter_ids = record_action_counter_ids;
            opt.request_stats_ids = request_stats_ids;
            super(opt, null, null);
        }
    }

    /// Logger class compatible with NodeBase.logStats().
    class TestLogger
    {
        import ocean.core.Traits : FieldName, hasMethod;
        import ocean.text.convert.Layout_tango;

        mstring output;

        void add ( S ) ( S str )
        {
            static assert(is(S == struct));
            foreach ( i, field; str.tupleof )
            {
                Layout!(char).format(this.output, "{}:{} ",
                    FieldName!(i, S), field);
            }
        }

        void addObject ( istring category, S ) ( cstring id, S str )
        {
            static assert(is(S == struct));
            foreach ( i, field; str.tupleof )
            {
                Layout!(char).format(this.output, "{}/{}/{}:{} ",
                    category, id, FieldName!(i, S), field);
            }
        }
    }
}

/*******************************************************************************

    Tests for logging of default, un-set stats with NodeBase.logStats().

*******************************************************************************/

unittest
{
    // No request or action stats.
    {
        auto node = new TestNode([], []);
        auto logger = new TestLogger;

        node.logStats(logger);
        test!("==")(logger.output,
            "bytes_sent:0 bytes_received:0 handling_connections:0 handling_connections_pcnt:0 ");
    }

    // One action. (Note that it's inconvenient to test with multiple actions,
    // as the order of logging depends on the order in which they're stored in
    // an internal AA.)
    {
        auto node = new TestNode(["written"], []);
        auto logger = new TestLogger;

        node.logStats(logger);
        test!("==")(logger.output,
            "bytes_sent:0 bytes_received:0 handling_connections:0 handling_connections_pcnt:0 "
            "action/written/records:0 action/written/bytes:0 ");
    }


    // One request. (Note that it's inconvenient to test with multiple requests,
    // as the order of logging depends on the order in which they're stored in
    // an internal AA.)
    {
        auto node = new TestNode([], ["Put"]);
        auto logger = new TestLogger;

        node.logStats(logger);
        test!("==")(logger.output,
            "bytes_sent:0 bytes_received:0 handling_connections:0 handling_connections_pcnt:0 "
            "request/Put/max_active:0 request/Put/handled:0 "
            "request/Put/mean_handled_time_micros:-nan request/Put/handled_10_micros:0 "
            "request/Put/handled_100_micros:0 request/Put/handled_1_ms:0 "
            "request/Put/handled_10_ms:0 request/Put/handled_100_ms:0 "
            "request/Put/handled_over_100_ms:0 ");
    }

    // One request and one action.
    {
        auto node = new TestNode(["written"], ["Put"]);
        auto logger = new TestLogger;

        node.logStats(logger);
        test!("==")(logger.output,
            "bytes_sent:0 bytes_received:0 handling_connections:0 handling_connections_pcnt:0 "
            "request/Put/max_active:0 request/Put/handled:0 "
            "request/Put/mean_handled_time_micros:-nan request/Put/handled_10_micros:0 "
            "request/Put/handled_100_micros:0 request/Put/handled_1_ms:0 "
            "request/Put/handled_10_ms:0 request/Put/handled_100_ms:0 "
            "request/Put/handled_over_100_ms:0 "
            "action/written/records:0 action/written/bytes:0 ");
    }
}

/*******************************************************************************

    Tests for logging of set stats with NodeBase.logStats().

*******************************************************************************/

unittest
{
    // Test for global stats.
    {
        auto node = new TestNode([], []);
        auto logger = new TestLogger;

        node.io_stats.bytes_sent += 23;
        node.io_stats.bytes_received += 23;
        node.logStats(logger);
        test!("==")(logger.output,
            "bytes_sent:23 bytes_received:23 handling_connections:0 handling_connections_pcnt:0 ");

        // Test that the counters have been reset by the last call to logStats().
        logger.output.length = 0;
        node.logStats(logger);
        test!("==")(logger.output,
            "bytes_sent:0 bytes_received:0 handling_connections:0 handling_connections_pcnt:0 ");
    }

    // Test for action stats.
    {
        auto node = new TestNode(["written"], []);
        auto logger = new TestLogger;

        node.record_action_counters.increment("written", 23);
        node.logStats(logger);
        test!("==")(logger.output,
            "bytes_sent:0 bytes_received:0 handling_connections:0 handling_connections_pcnt:0 "
            "action/written/records:1 action/written/bytes:23 ");

        // Test that the counters have been reset by the last call to logStats().
        logger.output.length = 0;
        node.logStats(logger);
        test!("==")(logger.output,
            "bytes_sent:0 bytes_received:0 handling_connections:0 handling_connections_pcnt:0 "
            "action/written/records:0 action/written/bytes:0 ");
    }

    // Test for request stats.
    {
        auto node = new TestNode([], ["Put"]);
        auto logger = new TestLogger;

        // Start a request.
        node.request_stats.started("Put");
        node.logStats(logger);
        test!("==")(logger.output,
            "bytes_sent:0 bytes_received:0 handling_connections:0 handling_connections_pcnt:0 "
            "request/Put/max_active:1 request/Put/handled:0 "
            "request/Put/mean_handled_time_micros:-nan request/Put/handled_10_micros:0 "
            "request/Put/handled_100_micros:0 request/Put/handled_1_ms:0 "
            "request/Put/handled_10_ms:0 request/Put/handled_100_ms:0 "
            "request/Put/handled_over_100_ms:0 ");

        // Finish a request.
        node.request_stats.finished("Put");
        logger.output.length = 0;
        node.logStats(logger);
        test!("==")(logger.output,
            "bytes_sent:0 bytes_received:0 handling_connections:0 handling_connections_pcnt:0 "
            "request/Put/max_active:1 request/Put/handled:1 "
            "request/Put/mean_handled_time_micros:0.00 request/Put/handled_10_micros:0 "
            "request/Put/handled_100_micros:0 request/Put/handled_1_ms:0 "
            "request/Put/handled_10_ms:0 request/Put/handled_100_ms:0 "
            "request/Put/handled_over_100_ms:0 ");

        // Logging again, all request stats should have been reset.
        logger.output.length = 0;
        node.logStats(logger);
        test!("==")(logger.output,
            "bytes_sent:0 bytes_received:0 handling_connections:0 handling_connections_pcnt:0 "
            "request/Put/max_active:0 request/Put/handled:0 "
            "request/Put/mean_handled_time_micros:-nan request/Put/handled_10_micros:0 "
            "request/Put/handled_100_micros:0 request/Put/handled_1_ms:0 "
            "request/Put/handled_10_ms:0 request/Put/handled_100_ms:0 "
            "request/Put/handled_over_100_ms:0 ");

        // Start then finish a request with timing info.
        node.request_stats.started("Put");
        node.request_stats.finished("Put", 23);
        logger.output.length = 0;
        node.logStats(logger);
        test!("==")(logger.output,
            "bytes_sent:0 bytes_received:0 handling_connections:0 handling_connections_pcnt:0 "
            "request/Put/max_active:1 request/Put/handled:1 "
            "request/Put/mean_handled_time_micros:23.00 request/Put/handled_10_micros:0 "
            "request/Put/handled_100_micros:1 request/Put/handled_1_ms:0 "
            "request/Put/handled_10_ms:0 request/Put/handled_100_ms:0 "
            "request/Put/handled_over_100_ms:0 ");
    }
}
