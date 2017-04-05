/*******************************************************************************

    Channels-based node base class

    Extends the node base class with the following features:
        * Contains a set of storage channels.

    copyright:      Copyright (c) 2012-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.node.model.ChannelsNode;



/*******************************************************************************

    Imports

*******************************************************************************/

import swarm.node.model.Node;

import swarm.node.model.IChannelsNodeInfo;

import swarm.node.connection.ConnectionHandler;

import swarm.node.storage.model.IStorageChannels;
import swarm.node.storage.model.IStorageEngine;
import swarm.node.storage.model.IStorageEngineInfo;

import ocean.transition;

/*******************************************************************************

    Channels node base template.

    Template params:
        Storage = type of storage channel node is based upon (the node contains
            a set of instances of this type)
        ConnHandler = type of connection handler (the node contains a
            SelectListener instance which owns a pool of instances of this type)

*******************************************************************************/

public class ChannelsNodeBase
    ( Storage : IStorageEngine, ConnHandler : ISwarmConnectionHandler )
    : NodeBase!(ConnHandler), IChannelsNodeInfo
{
    /***************************************************************************

        Storage channel registry instance

    ***************************************************************************/

    protected alias IStorageChannelsTemplate!(Storage) NodeStorageChannels;

    protected NodeStorageChannels channels;


    /***************************************************************************

        Constructor

        Params:
            node = node addres & port
            channels = storage channels instance
            conn_setup_params = connection handler constructor arguments
            backlog = (see ISelectListener ctor)

    ***************************************************************************/

    public this ( NodeItem node, NodeStorageChannels channels,
        ConnectionSetupParams conn_setup_params, int backlog )
    {
        this.channels = channels;

        super(node, conn_setup_params, backlog);
    }


    /***************************************************************************

        Shuts down the storage channels (may initiate dumping of channels to
        disk).

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

        Returns:
            number of records stored

    ***************************************************************************/

    public ulong num_records ( )
    {
        ulong r;
        foreach ( channel; this.channels )
        {
            r += channel.num_records;
        }
        return r;
    }


    /***************************************************************************

        Returns:
            number of bytes stored

    ***************************************************************************/

    public ulong num_bytes ( )
    {
        ulong b;
        foreach ( channel; this.channels )
        {
            b += channel.num_bytes;
        }
        return b;
    }


    /***************************************************************************

        Iterator over the ids of the queue's channels with their current and
        maximum size.

     **************************************************************************/

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


    /***************************************************************************

        Looks up channels by id.

        Params:
            id = id of channel to look up

        Returns:
            pointer to storage engine (may be null if no channel exists with the
            specified id)

    ***************************************************************************/

    public IStorageEngineInfo* opIn_r ( cstring id )
    {
        return cast(IStorageEngineInfo*)(id in this.channels);
    }


    /***************************************************************************

        Returns:
             string identifying the type of the node's storage engine

    ***************************************************************************/

    public cstring storage_type ( )
    {
        return this.channels.type;
    }
}


version (UnitTest)
{
    import ocean.net.server.connection.IConnectionHandler;

    private class TestConnectionHandler : ISwarmConnectionHandler
    {
        public this (void delegate(IConnectionHandler) a, ConnectionSetupParams b)
        {
            super(a, b);
        }
        override protected void handleCommand () {}
    }

    private class TestStorageEngine : IStorageEngine
    {
        public this ()
        {
            super(null);
        }
        override public typeof(this) clear () { return this; }
        override public typeof(this) close () { return this; }
        public ulong num_records () { return 42; }
        public ulong num_bytes () { return 42; }
    }
}

unittest
{
    alias ChannelsNodeBase!(TestStorageEngine, TestConnectionHandler) Instance;
}
