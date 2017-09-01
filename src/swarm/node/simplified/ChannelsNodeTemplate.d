/*******************************************************************************

    Class template for a swarm node with legacy protocol and storage channels.

    Extends swarm.node.simplified.NodeTemplate with a set of storage channels.

    TODO: this module is a replacement of the deprecated
    swarm.node.model.ChannelsNode. The difference is that this class melds in
    all neo functionality. When the deprecated module is removed, this module
    may be moved into its place.

    copyright:
        Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.node.simplified.ChannelsNodeTemplate;

import swarm.node.simplified.LegacyConnectionHandlerBase;
import swarm.node.simplified.NodeTemplate;
import swarm.node.storage.model.IStorageEngine;

import ocean.transition;

/*******************************************************************************

    Channels node base template.

    Template params:
        Storage = type of storage channel node is based upon (the node contains
            a set of instances of this type)
        ConnHandler = type of connection handler (the node contains a
            SelectListener instance which owns a pool of instances of this type)

*******************************************************************************/

public class ChannelsNodeTemplate
    ( Storage : IStorageEngine, ConnHandler : LegacyConnectionHandlerBase )
    : NodeTemplate!(ConnHandler)
{
    import swarm.node.storage.model.IStorageChannels;

    /// Storage channels type alias.
    protected alias IStorageChannelsTemplate!(Storage) NodeStorageChannels;

    /// Storage channels instance.
    protected NodeStorageChannels channels;

    /// Struct wrapping informational methods relating to the storage channels.
    private struct StorageInfo
    {
        import swarm.node.storage.model.IStorageEngineInfo;

        /// Storage channels instance.
        private NodeStorageChannels channels;

        /***********************************************************************

            Returns:
                number of records stored in all channels combined

        ***********************************************************************/

        public ulong num_records ( )
        {
            ulong r;
            foreach ( channel; this.channels )
            {
                r += channel.num_records;
            }
            return r;
        }

        /***********************************************************************

            Returns:
                number of bytes stored in all channels combined

        ***********************************************************************/

        public ulong num_bytes ( )
        {
            ulong b;
            foreach ( channel; this.channels )
            {
                b += channel.num_bytes;
            }
            return b;
        }

        /***********************************************************************

            Iterator over the ids of the queue's channels with their current and
            maximum size.

         **********************************************************************/

        public int opApply ( int delegate ( ref IStorageEngineInfo ) dg )
        {
            int result = 0;

            foreach ( channel; this.channels )
            {
                IStorageEngineInfo channel_info = channel;

                result = dg(channel_info);

                if (result) break;
            }

            return result;
        }

        /***********************************************************************

            Looks up channels by id.

            Params:
                id = id of channel to look up

            Returns:
                pointer to storage engine (may be null if no channel exists with
                the specified id)

        ***********************************************************************/

        public IStorageEngineInfo* opIn_r ( cstring id )
        {
            return cast(IStorageEngineInfo*)(id in this.channels);
        }

        /***********************************************************************

            Returns:
                 string identifying the type of the node's storage engine

        ***********************************************************************/

        public cstring storage_type ( )
        {
            return this.channels.type;
        }
    }

    /// Storage channels info.
    public StorageInfo storage_info;

    /***************************************************************************

        Constructor

        Params:
            node = node addres & legacy port
            neo_port = port of neo listener (same address as above)
            options = options for the neo node and connection handlers
            channels = storage channels instance
            backlog = (see ISelectListener ctor)

    ***************************************************************************/

    public this ( Options options, NodeStorageChannels channels )
    {
        super(options);

        this.storage_info.channels = this.channels = channels;
    }

    /***************************************************************************

        Shuts down the node's internals -- the storage channels, in this case.
        (May initiate dumping of channels to disk.)

    ***************************************************************************/

    override public void shutdown ( )
    {
        this.channels.shutdown;
    }

    /***************************************************************************

        Flushes write buffers of stream connections.

    ***************************************************************************/

    override public void flush ( )
    {
        foreach ( channel; this.channels )
        {
            channel.flush();
        }
    }

    /***************************************************************************

        Logs the node's stats, including channel stats.

        Params:
            Logger = type of stats logger (templated for ease of unittesting)
            stats_log = stats logger to write to

    ***************************************************************************/

    public void logStats ( Logger = StatsLog ) ( Logger stats_log )
    {
        this.logStorageStats(stats_log);
        this.logChannelStats(stats_log);
        super.logStats(stats_log);
    }

    /***************************************************************************

        Logs the storage channels global stats.

        Params:
            Logger = type of stats logger (templated for ease of unittesting)
            stats_log = stats logger to write to

    ***************************************************************************/

    protected void logStorageStats ( Logger = StatsLog ) ( Logger stats_log )
    {
        struct StorageStats
        {
            ulong total_bytes;
            ulong total_records;
        }

        StorageStats stats;
        stats.total_bytes = this.storage_info.num_bytes;
        stats.total_records = this.storage_info.num_records;

        stats_log.add(stats);
    }

    /***************************************************************************

        Logs the per-channel stats.

        Params:
            Logger = type of stats logger (templated for ease of unittesting)
            stats_log = stats logger to write to

    ***************************************************************************/

    protected void logChannelStats ( Logger = StatsLog ) ( Logger stats_log )
    {
        struct ChannelStats
        {
            ulong bytes;
            ulong records;
        }

        foreach ( channel; this.channels )
        {
            ChannelStats stats;
            stats.bytes = channel.num_bytes;
            stats.records = channel.num_records;
            stats_log.addObject!("channel")(channel.id, stats);
        }
    }
}

/*******************************************************************************

    Unit test helpers

*******************************************************************************/

version ( UnitTest )
{
    import ocean.core.Test;
    import swarm.node.simplified.NodeBase;
    import swarm.node.storage.model.IStorageChannels;

    class TestConnectionHandler : LegacyConnectionHandlerBase
    {
        import ocean.net.server.connection.IConnectionHandler;

        public this (void delegate(IConnectionHandler) a, NodeBase b)
        {
            super(a, b);
        }
        override protected void handleCommand () {}
    }

    class TestStorageEngine : IStorageEngine
    {
        public this ()
        {
            super(null);
        }
        override public typeof(this) clear () { return this; }
        override public typeof(this) close () { return this; }
        public ulong num_records () { return 0; }
        public ulong num_bytes () { return 0; }
    }

    class TestStorageChannels : IStorageChannelsTemplate!(TestStorageEngine)
    {
        this ( )
        {
            super(0);
        }

        override public cstring type ( )
        {
            return "test";
        }

        override protected TestStorageEngine create_ ( cstring channel_id )
        {
            return new TestStorageEngine;
        }
    }

    class TestChannelsNode :
        ChannelsNodeTemplate!(TestStorageEngine, TestConnectionHandler)
    {
        this ( istring[] record_action_counter_ids, istring[] request_stats_ids,
            istring[] channel_ids )
        {
            Options opt;
            opt.addr = "127.0.0.1";
            opt.support_neo = false;
            opt.record_action_counter_ids = record_action_counter_ids;
            opt.request_stats_ids = request_stats_ids;
            super(opt, new TestStorageChannels);

            foreach ( id; channel_ids )
                this.channels.getCreate(id);
        }
    }
}

/*******************************************************************************

    Test template instantiation.

*******************************************************************************/

unittest
{
    alias ChannelsNodeTemplate!(TestStorageEngine, TestConnectionHandler)
        Instance;
}

/*******************************************************************************

    Tests for logging extra channels node stats.

*******************************************************************************/

unittest
{
    // No channels.
    {
        auto node = new TestChannelsNode([], [], []);
        auto logger = new TestLogger;

        node.logStats(logger);
        test!("==")(logger.output,
            "total_bytes:0 total_records:0 " ~
            "bytes_sent:0 bytes_received:0 handling_connections:0 handling_connections_pcnt:0 ");
    }

    // One channel.
    {
        auto node = new TestChannelsNode([], [], ["test"]);
        auto logger = new TestLogger;

        node.logStats(logger);
        test!("==")(logger.output,
            "total_bytes:0 total_records:0 " ~
            "channel/test/bytes:0 channel/test/records:0 " ~
            "bytes_sent:0 bytes_received:0 handling_connections:0 handling_connections_pcnt:0 ");
    }
}
