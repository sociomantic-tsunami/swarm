/*******************************************************************************

    Node stats logging helper classes.

    copyright: Copyright (c) 2015-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.util.node.log.Stats;


/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.util.log.Stats;

import ocean.transition;

/*******************************************************************************

    Convenience alias for basic node stats logger (hides the template from the
    end user).

    Logs the following info from an INodeInfo instance:
        * Global stats about the node: bytes_sent, bytes_received,
          handling_connections, handling_connections_pcnt.
        * Per-request stats: request/X/handled, request/X/max_active.
        * Per-action stats: action/X/records, action/X/bytes.

*******************************************************************************/

public alias NodeStatsTemplate!(StatsLog) NodeStats;


/*******************************************************************************

    Convenience alias for channels node stats logger (hides the template from
    the end user).

    In addition to the information logged by NodeStats, logs the following info
    from an IChannelsNodeInfo instance:
        * Global stats about the node: total_bytes, total_records.
        * Per-channel stats: channel/X/bytes, channel/X/records.

*******************************************************************************/

public alias ChannelsNodeStatsTemplate!(StatsLog) ChannelsNodeStats;


/*******************************************************************************

    Basic node stats logger.

    Template params:
        Logger = type of logger to use. (The class is templated in order to
            allow it to be unittested without writing to a real log file.)

*******************************************************************************/

private class NodeStatsTemplate ( Logger = StatsLog )
{
    import swarm.node.model.INodeInfo;

    /***************************************************************************

        The template may only be instantiated with another logger than StatsLog
        in unittests.

    ***************************************************************************/

    version ( UnitTest ) { }
    else
    {
        static assert(is(Logger == StatsLog));
    }

    /***************************************************************************

        Info interface for node to be monitored.

    ***************************************************************************/

    protected INodeInfo node;

    /***************************************************************************

        Stats log instance to write to.

    ***************************************************************************/

    protected Logger stats_log;

    /***************************************************************************

        Constructor.

        Params:
            node = node to monitor
            stats_log = stats log to write to

    ***************************************************************************/

    public this ( INodeInfo node, Logger stats_log )
    {
        assert(node);
        assert(stats_log);

        this.node = node;
        this.stats_log = stats_log;
    }

    /***************************************************************************

        Outputs stats about the node to the stats log and resets the node's
        stats counters.

    ***************************************************************************/

    public void log ( )
    {
        if ( !this.node )
            return;

        this.logGlobalStats();
        this.logRequestStats();
        this.logActionStats();

        this.node.resetCounters(); // also resets the action counters
        this.node.request_stats.resetCounters();
    }

    /***************************************************************************

        Logs the global stats.

    ***************************************************************************/

    protected void logGlobalStats ( )
    {
        struct GlobalStats
        {
            ulong bytes_sent;
            ulong bytes_received;
            size_t handling_connections;
            ubyte handling_connections_pcnt;
        }

        GlobalStats stats;
        stats.bytes_sent = this.node.bytes_sent;
        stats.bytes_received = this.node.bytes_received;
        stats.handling_connections = this.node.num_open_connections;

        if ( this.node.connection_limit )
        {
            stats.handling_connections_pcnt = cast(ubyte)
                ((this.node.num_open_connections * 100.0f)
                / this.node.connection_limit);
        }

        this.stats_log.add(stats);
    }

    /***************************************************************************

        Logs the per-action stats.

    ***************************************************************************/

    protected void logActionStats ( )
    {
        foreach ( id, stats; this.node.record_action_counters )
        {
            this.stats_log.addObject!("action")(id, stats);
        }
    }

    /***************************************************************************

        Logs the per-request stats.

    ***************************************************************************/

    private void logRequestStats ( )
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

        foreach ( id, request; this.node.request_stats.request_stats )
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

            this.stats_log.addObject!("request")(id, stats);
        }
    }
}


/*******************************************************************************

    Channels node stats logger.

    Template params:
        Logger = type of logger to use (The class is templated in order to
            allow it to be unittested without writing to a real log file.)

*******************************************************************************/

private class ChannelsNodeStatsTemplate ( Logger = StatsLog )
    : NodeStatsTemplate!(Logger)
{
    import swarm.node.model.IChannelsNodeInfo;
    import swarm.node.model.INodeInfo;

    /***************************************************************************

        Info interface for channels node to be monitored.

    ***************************************************************************/

    protected IChannelsNodeInfo channels_node;

    /***************************************************************************

        Constructor.

        Params:
            node = node to monitor
            stats_log = stats log to write to

    ***************************************************************************/

    public this ( INodeInfo node, Logger stats_log )
    {
        super(node, stats_log);

        this.channels_node = cast(IChannelsNodeInfo)node;
    }

    /***************************************************************************

        Overrides the super class' method to add the following:
            * the total bytes and records stored in all channels
            * the per-channel stats

    ***************************************************************************/

    override protected void logGlobalStats ( )
    {
        super.logGlobalStats();

        if ( !this.channels_node )
            return;

        struct ChannelsGlobalStats
        {
            ulong total_bytes;
            ulong total_records;
        }

        ChannelsGlobalStats stats;
        stats.total_bytes = this.channels_node.num_bytes;
        stats.total_records = this.channels_node.num_records;

        this.stats_log.add(stats);

        this.logChannelStats();
    }

    /***************************************************************************

        Logs the per-channel stats.

    ***************************************************************************/

    protected void logChannelStats ( )
    {
        struct ChannelStats
        {
            ulong bytes;
            ulong records;
        }

        foreach ( channel; this.channels_node )
        {
            ChannelStats stats;
            stats.bytes = channel.num_bytes;
            stats.records = channel.num_records;
            this.stats_log.addObject!("channel")(channel.id, stats);
        }
    }
}


/*******************************************************************************

    Unittest helpers

*******************************************************************************/

version ( UnitTest )
{
    import ocean.core.Test;
    import swarm.node.model.INodeInfo : TestNode;
    import swarm.node.model.IChannelsNodeInfo : TestChannelsNode;

    /***************************************************************************

        Logger class compatible with NodeStatsTemplate

    ***************************************************************************/

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

    Tests for logging of default, unmodified stats with NodeStats

*******************************************************************************/

unittest
{
    // No request or action stats.
    {
        auto node = new TestNode([], []);
        auto log = new TestLogger;
        auto stats = new NodeStatsTemplate!(TestLogger)(node, log);

        stats.log();
        test!("==")(log.output,
            "bytes_sent:0 bytes_received:0 handling_connections:0 handling_connections_pcnt:0 ");
    }

    // One request. (Note that it's inconvenient to test with multiple requests,
    // as the order of logging depends on the order in which they're stored in
    // an internal AA.)
    {
        auto node = new TestNode([], ["Put"]);
        auto log = new TestLogger;
        auto stats = new NodeStatsTemplate!(TestLogger)(node, log);

        stats.log();
        test!("==")(log.output,
            "bytes_sent:0 bytes_received:0 handling_connections:0 handling_connections_pcnt:0 "
            "request/Put/max_active:0 request/Put/handled:0 "
            "request/Put/mean_handled_time_micros:-nan request/Put/handled_10_micros:0 "
            "request/Put/handled_100_micros:0 request/Put/handled_1_ms:0 "
            "request/Put/handled_10_ms:0 request/Put/handled_100_ms:0 "
            "request/Put/handled_over_100_ms:0 ");
    }

    // One action. (Note that it's inconvenient to test with multiple actions,
    // as the order of logging depends on the order in which they're stored in
    // an internal AA.)
    {
        auto node = new TestNode(["written"], []);
        auto log = new TestLogger;
        auto stats = new NodeStatsTemplate!(TestLogger)(node, log);

        stats.log();
        test!("==")(log.output,
            "bytes_sent:0 bytes_received:0 handling_connections:0 handling_connections_pcnt:0 "
            "action/written/records:0 action/written/bytes:0 ");
    }

    // One request and one action.
    {
        auto node = new TestNode(["written"], ["Put"]);
        auto log = new TestLogger;
        auto stats = new NodeStatsTemplate!(TestLogger)(node, log);

        stats.log();
        test!("==")(log.output,
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

    Tests for logging of modified stats with NodeStats

*******************************************************************************/

unittest
{
    // Test for global counters
    {
        auto node = new TestNode([], []);
        auto log = new TestLogger;
        auto stats = new NodeStatsTemplate!(TestLogger)(node, log);

        node.receivedBytes(23);
        node.sentBytes(23);
        stats.log();
        test!("==")(log.output,
            "bytes_sent:23 bytes_received:23 handling_connections:0 handling_connections_pcnt:0 ");

        // Test that the counters have been reset
        log.output.length = 0;
        stats.log();
        test!("==")(log.output,
            "bytes_sent:0 bytes_received:0 handling_connections:0 handling_connections_pcnt:0 ");
    }

    // Test for action stats
    {
        auto node = new TestNode(["written"], []);
        auto log = new TestLogger;
        auto stats = new NodeStatsTemplate!(TestLogger)(node, log);

        node.record_action_counters.increment("written", 23);
        stats.log();
        test!("==")(log.output,
            "bytes_sent:0 bytes_received:0 handling_connections:0 handling_connections_pcnt:0 "
            "action/written/records:1 action/written/bytes:23 ");

        // Test that the action stats have been reset
        log.output.length = 0;
        stats.log();
        test!("==")(log.output,
            "bytes_sent:0 bytes_received:0 handling_connections:0 handling_connections_pcnt:0 "
            "action/written/records:0 action/written/bytes:0 ");
    }

    // Test for request stats
    {
        auto node = new TestNode([], ["Put"]);
        auto log = new TestLogger;
        auto stats = new NodeStatsTemplate!(TestLogger)(node, log);

        // Start a request
        node.request_stats.started("Put");
        stats.log();
        test!("==")(log.output,
            "bytes_sent:0 bytes_received:0 handling_connections:0 handling_connections_pcnt:0 "
            "request/Put/max_active:1 request/Put/handled:0 "
            "request/Put/mean_handled_time_micros:-nan request/Put/handled_10_micros:0 "
            "request/Put/handled_100_micros:0 request/Put/handled_1_ms:0 "
            "request/Put/handled_10_ms:0 request/Put/handled_100_ms:0 "
            "request/Put/handled_over_100_ms:0 ");

        // Finish a request
        node.request_stats.finished("Put");
        log.output.length = 0;
        stats.log();
        test!("==")(log.output,
            "bytes_sent:0 bytes_received:0 handling_connections:0 handling_connections_pcnt:0 "
            "request/Put/max_active:1 request/Put/handled:1 "
            "request/Put/mean_handled_time_micros:0.00 request/Put/handled_10_micros:0 "
            "request/Put/handled_100_micros:0 request/Put/handled_1_ms:0 "
            "request/Put/handled_10_ms:0 request/Put/handled_100_ms:0 "
            "request/Put/handled_over_100_ms:0 ");

        // Logging again, all request stats should have been reset
        log.output.length = 0;
        stats.log();
        test!("==")(log.output,
            "bytes_sent:0 bytes_received:0 handling_connections:0 handling_connections_pcnt:0 "
            "request/Put/max_active:0 request/Put/handled:0 "
            "request/Put/mean_handled_time_micros:-nan request/Put/handled_10_micros:0 "
            "request/Put/handled_100_micros:0 request/Put/handled_1_ms:0 "
            "request/Put/handled_10_ms:0 request/Put/handled_100_ms:0 "
            "request/Put/handled_over_100_ms:0 ");

        // Start then finish a request with timing info
        node.request_stats.started("Put");
        node.request_stats.finished("Put", 23);
        log.output.length = 0;
        stats.log();
        test!("==")(log.output,
            "bytes_sent:0 bytes_received:0 handling_connections:0 handling_connections_pcnt:0 "
            "request/Put/max_active:1 request/Put/handled:1 "
            "request/Put/mean_handled_time_micros:23.00 request/Put/handled_10_micros:0 "
            "request/Put/handled_100_micros:1 request/Put/handled_1_ms:0 "
            "request/Put/handled_10_ms:0 request/Put/handled_100_ms:0 "
            "request/Put/handled_over_100_ms:0 ");
    }
}

/*******************************************************************************

    Tests for logging with ChannelsNodeStats

*******************************************************************************/

unittest
{
    // No request, action, or channel stats.
    {
        auto node = new TestChannelsNode([], [], []);
        auto log = new TestLogger;
        auto stats = new ChannelsNodeStatsTemplate!(TestLogger)(node, log);

        stats.log();
        test!("==")(log.output,
            "bytes_sent:0 bytes_received:0 handling_connections:0 handling_connections_pcnt:0 "
            "total_bytes:0 total_records:0 ");
    }

    // One channel.
    {
        auto node = new TestChannelsNode([], [], ["test"]);
        auto log = new TestLogger;
        auto stats = new ChannelsNodeStatsTemplate!(TestLogger)(node, log);

        stats.log();
        test!("==")(log.output,
            "bytes_sent:0 bytes_received:0 handling_connections:0 handling_connections_pcnt:0 "
            "total_bytes:0 total_records:0 "
            "channel/test/bytes:0 channel/test/records:0 ");
    }
}

