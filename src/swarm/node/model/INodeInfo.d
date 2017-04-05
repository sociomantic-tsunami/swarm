/*******************************************************************************

    Information interface for node

    copyright:      Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

******************************************************************************/

module swarm.node.model.INodeInfo;



/*******************************************************************************

    Imports

*******************************************************************************/

import swarm.Const;

import swarm.node.request.RequestStats;

import swarm.node.model.RecordActionCounters;

import swarm.node.storage.model.IStorageEngineInfo;

import ocean.transition;

public interface INodeInfo
{
    /**************************************************************************

        Returns:
            NodeItem struct containing the address & port of the node

     **************************************************************************/

    public NodeItem node_item ( );


    /**************************************************************************

        Returns:
            the number of connections in the pool

     **************************************************************************/

    public size_t num_connections ( );


    /**************************************************************************

        Returns:
            the number of active connections currently being handled
            (Note: the number of idle connections in the pool can be calculated
            by num_connections - num_open_connections)

     **************************************************************************/

    public size_t num_open_connections ( );


    /**************************************************************************

        Returns:
            the limit of the number of connections (i.e. the maximum number of
            connections the node can handle in parallel) or 0 if limitation is
            disabled

     **************************************************************************/

    public size_t connection_limit ( );


    /**************************************************************************

        Returns:
            the statistics counters.

     **************************************************************************/

    public RecordActionCounters record_action_counters ( );


    /**************************************************************************

        Returns:
            number of bytes received

     **************************************************************************/

    public ulong bytes_received ( );


    /**************************************************************************

        Returns:
            number of bytes sent

     **************************************************************************/

    public ulong bytes_sent ( );


    /**************************************************************************

        Increments the count of received bytes by the specified amount.

        Params:
            bytes = number of bytes received

     **************************************************************************/

    public void receivedBytes ( size_t bytes );


    /**************************************************************************

        Increments the count of sent bytes by the specified amount.

        Params:
            bytes = number of bytes sent

     **************************************************************************/

    public void sentBytes ( size_t bytes );


    /**************************************************************************

        Resets the count of received / sent bytes and records handled.

     **************************************************************************/

    public void resetCounters ( );


    /***************************************************************************

        Returns:
            per-request stats tracking instance

    ***************************************************************************/

    public RequestStats request_stats ( );
}


/*******************************************************************************

    Stub node class which implements INodeInfo, for use in unittests.

*******************************************************************************/

version ( UnitTest )
{
    public class TestNode : INodeInfo
    {
        /***********************************************************************

            Fields for the public getter/setter methods.

        ***********************************************************************/

        NodeItem node_item_;
        size_t num_connections_;
        size_t num_open_connections_;
        size_t connection_limit_;
        ulong bytes_received_;
        ulong bytes_sent_;
        ulong records_handled_;
        RecordActionCounters record_action_counters_;
        RequestStats request_stats_;

        /***********************************************************************

            Constructor.

            Params:
                actions = list of record action types to track stats for
                requests = list of request types to track stats for

        ***********************************************************************/

        this ( istring[] actions, istring[] requests )
        {
            this.record_action_counters_ = new RecordActionCounters(actions);
            this.request_stats_ = new RequestStats;
            foreach ( request; requests )
            {
                this.request_stats_.init(request);
            }
        }

        /***********************************************************************

            Implementations of INodeInfo methods

        ***********************************************************************/

        override NodeItem node_item ( )
        {
            return this.node_item_;
        }

        override size_t num_connections ( )
        {
            return this.num_connections_;
        }

        override size_t num_open_connections ( )
        {
            return this.num_open_connections_;
        }

        override size_t connection_limit ( )
        {
            return this.connection_limit_;
        }

        override ulong bytes_received ( )
        {
            return this.bytes_received_;
        }

        override ulong bytes_sent ( )
        {
            return this.bytes_sent_;
        }

        override void receivedBytes ( size_t bytes )
        {
            this.bytes_received_ += bytes;
        }

        override void sentBytes ( size_t bytes )
        {
            this.bytes_sent_ += bytes;
        }

        override RecordActionCounters record_action_counters ( )
        {
            return this.record_action_counters_;
        }

        override RequestStats request_stats ( )
        {
            return this.request_stats_;
        }

        override void resetCounters ( )
        {
            // Mimicks the behaviour of the real Node, resetting the global
            // counters plus the action counters.
            this.bytes_received_ = 0;
            this.bytes_sent_ = 0;
            this.records_handled_ = 0;

            this.record_action_counters.reset();
        }
    }
}

