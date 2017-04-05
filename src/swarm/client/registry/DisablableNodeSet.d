/*******************************************************************************

    Version:        2014-01-23: Initial release

    Authors:        Gavin Norman

    Class wrapping a list and map of connection pools. Extends the basic NodeSet
    class with the ability to disable and re-enable nodes (as opposed to add/
    remove, which requires the construction of a new NodeConnectionPool each
    time).

    Copyright:      Copyright (c) 2014-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.registry.DisablableNodeSet;



/*******************************************************************************

    Imports

*******************************************************************************/

import swarm.Const : NodeItem;

import swarm.client.connection.NodeConnectionPool;

import swarm.client.registry.NodeSet;

import ocean.core.Enforce;



public class DisablableNodeSet : NodeSet
{
    /***************************************************************************

        Map of disabled nodes (indexed by address/port). When a node is
        disabled, the associated connection pool is removed from the set and
        placed in this map. If the node is re-enabled at a later date, its
        connection pool is retrieved from this map and reinstated in the set.

    ***************************************************************************/

    private ConnPoolByNode disabled_nodes;


    /***************************************************************************

        Constructor.

        Params:
            expected_nodes = expected number of nodes in the set
            modified = delegate to call when node set is modified

    ***************************************************************************/

    public this ( size_t expected_nodes, ModifiedDg modified )
    {
        super(expected_nodes, modified);

        this.disabled_nodes = new ConnPoolByNode(expected_nodes / 2);
    }


    /***************************************************************************

        Disables a node connection in the set. The disabled node is added to the
        internal list of disabled nodes, ready to be reinstated when requested.

        Params:
            node = node address/port

        Throws:
            exception if the node does not exist in the set

    ***************************************************************************/

    public void disable ( NodeItem node )
    out
    {
        assert(!(node in this.map), "node in set after disable()");
        assert(node in this.disabled_nodes, "node not disabled after disable()");
    }
    body
    {
        assert(!(node in this.disabled_nodes), "node already disabled");

        this.disabled_nodes[node] = this.remove(node); // calls this.modified()
    }


    /***************************************************************************

        Re-enables a node connection in the set. The node is found in the list
        of disabled nodes and is reinstated to the set.

        Params:
            node = node address/port

        Throws:
            exception if the node does not exist in the list of disabled nodes

    ***************************************************************************/

    public void enable ( NodeItem node )
    out
    {
        assert(node in this.map, "node not in set after enable()");
        assert(!(node in this.disabled_nodes), "node disabled after enabled()");
    }
    body
    {
        auto conn_pool = node in this.disabled_nodes;
        enforce(this.no_node_exception(node.Address, node.Port), conn_pool !is null);

        this.add(node, *conn_pool); // calls this.modified()
        this.disabled_nodes.remove(node);
    }


    /***************************************************************************

        Returns:
            the number of nodes which have been disabled

    ***************************************************************************/

    public size_t num_disabled ( )
    {
        return this.disabled_nodes.bucket_info.length;
    }


    /***************************************************************************

        opApply iterator over the address/port of disabled nodes and the
        associated pool of connections.

    ***************************************************************************/

    public int opApply ( int delegate ( ref NodeItem, ref NodeConnectionPool ) dg )
    {
        int res;
        foreach ( node_item, conn_pool; this.disabled_nodes )
        {
            res = dg(node_item, conn_pool);
            if ( res ) break;
        }
        return res;
    }
}
