/*******************************************************************************

    Version:        2014-01-23: Initial release

    Authors:        Gavin Norman

    Class wrapping a list and map of connection pools. The class accepts an
    optional delegate to be passed to its constructor, which will be called
    when the contents of the set are modified.

    Copyright:      Copyright (c) 2014-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.registry.NodeSet;



/*******************************************************************************

    Imports

*******************************************************************************/

import swarm.Const : NodeItem;

import swarm.client.connection.NodeConnectionPool;

import ocean.core.Exception;

import ocean.core.Enforce;

import ocean.util.container.map.Map : StandardKeyHashingMap;

import ocean.transition;

import ocean.text.convert.Format;



public class NodeSet
{
    /***************************************************************************

        Base class for exceptions thrown by the NodeSet

    ***************************************************************************/

    public static abstract class NodeSetException : Exception
    {
        /***********************************************************************

            Address of node

        ***********************************************************************/

        public cstring node_address;


        /***********************************************************************

            Port of node

        ***********************************************************************/

        public ushort node_port;


        /***********************************************************************

            Constructor

        ***********************************************************************/

        mixin DefaultExceptionCtor!();


        /***********************************************************************

            Sets the exception's info members and returns the instance, allowing
            the exception to be set and thrown thus:

            ---
                throw node_set_exception("192.168.2.171", 2222);
            ---

            Params:
                node_address = Address of the node
                node_port = Port of the node

            Returns:
                this instance

        ***********************************************************************/

        public typeof(this) opCall ( cstring node_address, ushort node_port )
        {
            this.node_address = node_address;
            this.node_port = node_port;

            this.msg = Format.convert("{}: {}:{} @{}:{}", super.msg,
                    this.node_address, this.node_port, this.file, this.line);

            return this;
        }
    }


    /***************************************************************************

        Exception that is thrown when the same node is added twice

    ***************************************************************************/

    public static class DuplicateNodeException : NodeSetException
    {
        /***********************************************************************

            Constructor

        ***********************************************************************/

        public this ( )
        {
            super("Node already exists in set");
        }
    }


    /***************************************************************************

        Exception that is thrown when a node does not exist in the set

    ***************************************************************************/

    public static class NoNodeException : NodeSetException
    {
        /***********************************************************************

            Constructor

        ***********************************************************************/

        public this ( )
        {
            super("Node does not exist in set");
        }
    }


    /***************************************************************************

        List of connection pools (for convenience of ordered indexing).

    ***************************************************************************/

    public NodeConnectionPool[] list;


    /***************************************************************************

        Map of nodes -> connection pools (for convenience of lookup by
        node).

    ***************************************************************************/

    protected alias StandardKeyHashingMap!(NodeConnectionPool, NodeItem)
        ConnPoolByNode;

    protected ConnPoolByNode map_;


    /***************************************************************************

        Delegate which is called when the node set is modified.

    ***************************************************************************/

    protected alias void delegate ( ) ModifiedDg;

    protected ModifiedDg modified_;


    /***************************************************************************

        Re-used exception instances.

    ***************************************************************************/

    protected DuplicateNodeException dup_node_exception;

    protected NoNodeException no_node_exception;


    /***************************************************************************

        Constructor. Constructs the nodes map.

        Params:
            expected_nodes = expected number of nodes in the set
            modified = delegate to call when node set is modified

    ***************************************************************************/

    public this ( size_t expected_nodes, ModifiedDg modified = null )
    {
        this.map_ = new ConnPoolByNode(expected_nodes);
        this.modified_ = modified;

        this.dup_node_exception = new DuplicateNodeException;
        this.no_node_exception = new NoNodeException;
    }


    /***************************************************************************

        Returns:
            Map of nodes -> connection pools (for convenience of lookup by node)

    ***************************************************************************/

    public ConnPoolByNode map ()
    {
        return this.map_;
    }


    /***************************************************************************

        Adds a connection pool associated with a node to the set, and calls the
        user-provided modified() delegate.

        Params:
            node = node address/port
            conn_pool = connection pool to add

        Throws:
            if the specified node is already associated with a connection pool
            in the set

    ***************************************************************************/

    public void add ( NodeItem node, NodeConnectionPool conn_pool )
    {
        enforce(this.dup_node_exception(node.Address, node.Port),
            !(node in this.map));

        this.list ~= conn_pool;
        this.map[node] = conn_pool;

        this.modified();
    }


    /***************************************************************************

        Removes the connection pool associated with a node from the set, and
        calls the user-provided modified() delegate.

        Params:
            node = node address/port

        Returns:
            connection pool for node which was just removed

        Throws:
            if the node does not exist in the set

    ***************************************************************************/

    public NodeConnectionPool remove ( NodeItem node )
    {
        // Look up conn pool in map
        auto conn_pool = node in this.map;
        enforce(this.no_node_exception(node.Address, node.Port),
            conn_pool !is null);

        // Find same conn pool in list
        size_t index = this.list.length;
        foreach ( i, cp; this.list )
        {
            if ( cp is *conn_pool )
            {
                index = i;
                break;
            }
        }
        assert(index < this.list.length, "connection pool list/map mismatch");

        // Remove from list
        this.list[index] = this.list[$-1];
        this.list.length = this.list.length - 1;
        enableStomping(this.list);

        // Remove from map
        this.map.remove(node);

        this.modified();

        return *conn_pool;
    }


    /***************************************************************************

        Calls the user-provided modified delegate, if non-null.

    ***************************************************************************/

    private void modified ( )
    {
        if ( this.modified_ )
        {
            this.modified_();
        }
    }
}
