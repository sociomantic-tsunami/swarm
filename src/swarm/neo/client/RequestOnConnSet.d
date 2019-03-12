/*******************************************************************************

    Struct encapsulating the set of RequestOnConn instances in use by an
    active request.

    Copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.neo.client.RequestOnConnSet;

import ocean.transition;
import ocean.core.Verify;

/*******************************************************************************

     Struct encapsulating the set of RequestOnConn instances in use by an
     active request.

*******************************************************************************/

public struct RequestOnConnSet
{
    import swarm.neo.client.RequestOnConn;
    import swarm.neo.util.TreeMap;
    import swarm.neo.AddrPort;

    invariant ( )
    {
        if ( this.type_ == RequestType.None )
        {
            assert(this.num_active == 0);
            assert(this.list.length == 0);
        }
    }

    /// Type of request currently using this instance.
    public enum RequestType
    {
        None,
        SingleNode, // Includes round-robin requests.
        MultiNode,
        AllNodes
    }

    /// ditto
    private RequestType type_;

    /// The number of request-on-conns of this request that are currently
    /// running, i.e. their fiber is running. Note that this number is not
    /// always equal to the number of request-on-conns in the set, as when a
    /// request-on-conn finishes, it is not removed from the set, but
    /// `num_active` is decremented.
    private uint num_active;

    /// Request-on-conns list used by requests that contact one or more nodes
    /// simultaneously, where each request-on-conn may freely switch between
    /// connections.
    private RequestOnConn[] list;

    /// Request-on-conns map, indexed by node address, used by requests that
    /// contact all nodes simultaneously, where each request-on-conn is bound to
    /// a single connection for its whole lifetime.
    private alias TreeMap!(RequestOnConn.TreeMapElement) RequestOnConnByNode;

    /// ditto
    private RequestOnConnByNode map;

    /***************************************************************************

        Initialises the set for use by a request of the specified type.

        Params:
            type = type of request

    ***************************************************************************/

    public void initialise ( RequestType type )
    {
        verify(type != RequestType.None);
        verify(this.num_active == 0);

        this.type_ = type;
        if ( type == RequestType.AllNodes )
            this.map.reinit();
    }

    /***************************************************************************

        Returns:
            type of request this instance has been initialised for (or None, if
            it's uninitialised)

    ***************************************************************************/

    public RequestType type ( ) /* d1to2fix_inject: const */
    {
        return this.type_;
    }

    /***************************************************************************

        Adds the specified request-on-conn to the set. May only be used by
        single-node or multi-node requests.

        Params:
            request_on_conn = the RequestOnConn instance to add to the set

        Returns:
            the just-added RequestOnConn instance

    ***************************************************************************/

    public RequestOnConn add ( RequestOnConn request_on_conn )
    {
        final switch ( this.type_ )
        {
            case RequestType.SingleNode:
                verify(this.list.length <= 1);
                verify(this.num_active <= 1);
                break;
            case RequestType.MultiNode:
                break;
            case RequestType.AllNodes, RequestType.None:
                verify(false);
            version (D_Version2) {} else default:
                assert(false);
        }

        this.list ~= request_on_conn;
        this.num_active++;
        request_on_conn.active = true;

        return request_on_conn;
    }

    /***************************************************************************

        Adds the specified request-on-conn to the set and associates it with the
        specified node. May only be used by all-nodes requests.

        Params:
            remote_address = address of node used by request_on_conn
            request_on_conn = the RequestOnConn instance to add to the set

        Returns:
            the just-added RequestOnConn instance

    ***************************************************************************/

    public RequestOnConn add ( AddrPort remote_address,
        RequestOnConn request_on_conn )
    {
        verify(this.type_ == RequestType.AllNodes);

        bool added;
        this.map.put(remote_address.cmp_id, added, request_on_conn);
        assert(added, typeof(this).stringof ~ ".add: a " ~
            "request-on-connection already exists for the specified node");

        this.num_active++;
        request_on_conn.active = true;

        return request_on_conn;
    }

    /***************************************************************************

        Iterates over the request-on-conns in the set. Note that as `finished`
        only decrements `num_active`, the iteration also covers request-on-conns
        that are finished.

        Params:
            dg = iteration delegate

        Returns:
            0 if the iteration finished or non-0 if the caller broke out of it

    ***************************************************************************/

    public int opApply ( int delegate ( ref RequestOnConn ) dg )
    {
        with ( RequestType ) final switch ( this.type_ )
        {
            case None:
                return 0;

            case SingleNode:
            case MultiNode:
                foreach ( roc; this.list )
                    if ( auto ret = dg(roc) )
                        return ret;
                return 0;

            case AllNodes:
                foreach ( roc; this.map )
                {
                    if ( auto ret = dg(roc) )
                        return ret;
                    if (this.num_active == 0)
                        break;
                }
                return 0;

            version (D_Version2) {} else default: assert(false);
        }

        assert(false);
    }

    /***************************************************************************

        Searches the request-on-conns in the set for one that is using the
        connection for the specified node address.

        Params:
            node_address = address of node to search for

        Returns:
            request-on-conn that is communicating with the specified node, or
            null if none is found

    ***************************************************************************/

    public RequestOnConn get ( AddrPort node_address )
    {
        with ( RequestType ) final switch ( this.type_ )
        {
            case None:
                return null;

            case SingleNode:
            case MultiNode:
                foreach ( roc; this.list )
                    if ( roc.connectedTo(node_address) )
                        return roc;
                return null;

            case AllNodes:
                return node_address.cmp_id in this.map;

            version (D_Version2) {} else default: assert(false);
        }

        assert(false);
    }

    /***************************************************************************

        Registers `roc` as inactive, decrements the `num_active` counter and
        returns whether the counter is now 0.

        Params:
            roc = the `RequestOnConn` instance that has finished

        Returns:
            true if `num_active` is 0

    ***************************************************************************/

    public bool finished ( RequestOnConn roc )
    {
        verify(this.num_active != 0);

        // TODO: Consider `this.all_nodes.remove(roc)` instead of using the
        // `active` flag. Not doing this now for a patch release to avoid
        // potentially introducing a bug if there is an unobvious reason why it
        // isn't done.
        roc.active = false;
        return --this.num_active == 0;
    }

    /***************************************************************************

        Clears this instance, including recycling all owned RequestOnConn
        instances via the provided recycle() delegate.

        Params:
            recycle = the delegate to call to recycle each RequestOnConn in the
            set

    ***************************************************************************/

    public void reset ( void delegate ( RequestOnConn ) recycle )
    {
        verify(this.num_active == 0);

        with ( RequestType ) final switch ( this.type_ )
        {
            case None:
                break;

            case SingleNode:
            case MultiNode:
                foreach ( roc; this.list )
                    recycle(roc);
                this.list.length = 0;
                enableStomping(this.list);
                break;

            case AllNodes:
                foreach ( roc; this.map )
                {
                    this.map.remove(roc);
                    recycle(roc);
                }
                break;

            version (D_Version2) {} else default: assert(false);
        }

        this.type_ = RequestType.None;
    }
}
