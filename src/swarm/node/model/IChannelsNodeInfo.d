/*******************************************************************************

    Information interface for channels-based node

    Note: at the moment, the assumption is that a node with channels is also a
    storage engine of some kind. This is not necessarily the case, and could be
    modified if need be at some point.

    copyright:      Copyright (c) 2012-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.node.model.IChannelsNodeInfo;



/*******************************************************************************

    Imports

*******************************************************************************/

import swarm.node.model.INodeInfo;

import swarm.Const;

import swarm.node.storage.model.IStorageEngineInfo;

import ocean.transition;

public interface IChannelsNodeInfo : INodeInfo
{
    /**************************************************************************

        Returns:
             string identifying the type of the node's storage engine

     **************************************************************************/

    public cstring storage_type ( );


    /***************************************************************************

        foreach iterator over information interfaces to the storage engines
        (i.e. the individual channels) in the node

    ***************************************************************************/

    public int opApply ( int delegate ( ref IStorageEngineInfo ) dg );


    /***************************************************************************

        Looks up channels by id.

        Params:
            id = id of channel to look up

        Returns:
            pointer to storage engine (may be null if no channel exists with the
            specified id)

    ***************************************************************************/

    public IStorageEngineInfo* opIn_r ( cstring id );


    /***************************************************************************

        Returns:
            total number of records stored (in all channels)

    ***************************************************************************/

    public ulong num_records ( );


    /***************************************************************************

        Returns:
            total number of bytes stored (in all channels)

    ***************************************************************************/

    public ulong num_bytes ( );
}


/*******************************************************************************

    Stub channels node class which implements IChannelsNodeInfo, for use in
    unittests.

*******************************************************************************/

version ( UnitTest )
{
    public class TestChannelsNode : TestNode, IChannelsNodeInfo
    {
        /***********************************************************************

            Fields for the public getter/setter methods.

        ***********************************************************************/

        istring storage_type_ = "dummy";
        ulong num_records_;
        ulong num_bytes_;

        /***********************************************************************

            Per-channel statistics

        ***********************************************************************/

        static class ChannelStats : IStorageEngineInfo
        {
            /*******************************************************************

                Fields for the public getter/setter methods.

            *******************************************************************/

            istring id_;
            ulong num_records_;
            ulong num_bytes_;

            /*******************************************************************

                Constructor.

                Params:
                    id = channel name

            *******************************************************************/

            this ( istring id )
            {
                this.id_ = id;
            }

            /*******************************************************************

                Implementations of IStorageEngineInfo methods

            *******************************************************************/

            override cstring id ( )
            {
                return this.id_;
            }

            override ulong num_records ( )
            {
                return this.num_records_;
            }

            override ulong num_bytes ( )
            {
                return this.num_bytes_;
            }
        }

        ChannelStats[istring] channels;

        /***********************************************************************

            Constructor.

            Params:
                actions = list of record action types to track stats for
                requests = list of request types to track stats for
                channels = list of channels to track stats for

        ***********************************************************************/

        this ( istring[] actions, istring[] requests, istring[] channels )
        {
            super(actions, requests);

            foreach ( channel ; channels )
            {
                auto name = idup(channel);
                this.channels[name] = new ChannelStats(name);
            }
        }

        /***********************************************************************

            Implementations of IChannelsNodeInfo methods

        ***********************************************************************/

        override cstring storage_type ( )
        {
            return this.storage_type_;
        }

        override int opApply ( int delegate ( ref IStorageEngineInfo ) dg )
        {
            int r;
            foreach ( c; this.channels )
            {
                auto info = cast(IStorageEngineInfo)c;
                r = dg(info);
                if ( r ) break;
            }
            return r;
        }

        override IStorageEngineInfo* opIn_r ( cstring id )
        {
            return cast(IStorageEngineInfo*)(id in this.channels);
        }

        override ulong num_records ( )
        {
            return this.num_records_;
        }

        override ulong num_bytes ( )
        {
            return this.num_bytes_;
        }
    }
}

