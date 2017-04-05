/*******************************************************************************

    Information interface to a connection registry (set of pools of connections
    to nodes).

    Provides read-only methods for informational purposes.

    copyright:      Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.registry.model.INodeRegistryInfo;



/*******************************************************************************

    Imports

*******************************************************************************/

import swarm.client.connection.model.INodeConnectionPoolInfo;



public interface INodeRegistryInfo
{
    /***************************************************************************

        Returns:
            number of nodes in the registry

    ***************************************************************************/

    public size_t length ( );


    /***************************************************************************

        Returns:
            the maximum number of connections per node

    ***************************************************************************/

    public size_t max_connections_per_node ( );


    /***************************************************************************

        Returns:
            size (in bytes) of per-node queue of pending requests

    ***************************************************************************/

    public size_t queue_limit ( );


    /***************************************************************************

        Returns:
            the number of requests in all the per node request queues

    ***************************************************************************/

    public size_t queued_requests ( );


    /***************************************************************************

        Returns:
            the number of requests in all the per node overflow queues

    ***************************************************************************/

    public size_t overflowed_requests ( );


    /***************************************************************************

        'foreach' iteration over information interfaces to the node connection
        pools.

    ***************************************************************************/

    public int opApply ( int delegate ( ref INodeConnectionPoolInfo ) dg );
}

