/*******************************************************************************

    Struct encapsulating the set of RequestOnConn instances in use by an
    active request.

    Copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.client.RequestOnConnSet;

/*******************************************************************************

     Struct encapsulating the set of RequestOnConn instances in use by an
     active request.

*******************************************************************************/

public struct RequestOnConnSet
{
    import swarm.neo.client.RequestOnConn;
    import swarm.neo.util.TreeMap;
    import swarm.neo.IPAddress;

    /***************************************************************************

        Definition of the tree map of RequestOnConn objects by node
        address.

    ***************************************************************************/

    private alias TreeMap!(RequestOnConn.TreeMapElement)
        RequestOnConnByNode;

    /***************************************************************************

        The handlers and parameters specific to a single-node or all-nodes
        request. `is_all_nodes` tells which field is active.

        Whenever this request is inactive, the `single_node` field is active
        and set to its init value; see the constructor documentaion.

    ***************************************************************************/

    union
    {
        /***********************************************************************

            Active while this instance is used for a single-node request;
            Set by startSingleNode() and cleared by handlerFinished().

        ***********************************************************************/

        RequestOnConn single_node;

        /***********************************************************************

            Active while this instance is used for an all-nodes request:
            A tree map of the currently active handlers and the nodes they
            are using. Each handler is added just after starting the request
            fiber and removed just before the fiber terminates.
            Stays the same and non-empty while `Handler.all_nodes` is active
            (but the elements change).

        ***********************************************************************/

        RequestOnConnByNode all_nodes;
    }

    /***************************************************************************

        true if this is an all-nodes request (`all_nodes` is the active
        union field) or false if this is a single-node request
        (`single_node` is the active union field).
        Whenever this request is inactive, this flag is false, and the
        `single_node` field is active and set to its `init` value; see the
        constructor documentaion.

    ***************************************************************************/

    public bool is_all_nodes = false;

    /***************************************************************************

        The number of handlers of this request that are currently running,
        i.e. their fiber is running. These handlers do not necessarily use
        a node at all times.

        TODO: if TreeMap had a .length method, this could be replaced by a
        getter, rather than maintaining a count, internally

    ***************************************************************************/

    public uint num_active;

    /***************************************************************************

        Sets set of active request-on-conns to the specified
        RequestOnConn instance (i.e. the set contains just this single
        element).

        Sets this object to a single RequestOnConn.

        Params:
            request_on_conn = the RequestOnConn instance to set

        Returns:
            the just-set RequestOnConn instance

    ***************************************************************************/

    public RequestOnConn setSingle ( RequestOnConn request_on_conn )
    {
        this.is_all_nodes = false;
        this.single_node = request_on_conn;
        this.num_active = 1;

        return request_on_conn;
    }

    /***************************************************************************

        Adds the specified RequestOnConn instance to the set of active
        request-on-conns.

        Params:
            request_on_conn = the RequestOnConn instance to set

        Returns:
            the just-set RequestOnConn instance

    ***************************************************************************/

    public RequestOnConn addMulti ( IPAddress remote_address,
        RequestOnConn request_on_conn )
    {
        this.is_all_nodes = true;

        bool added;
        this.all_nodes.put(remote_address.cmp_id, added, request_on_conn);
        assert(added, typeof(this).stringof ~ ".addMulti: a " ~
            "request-on-connection already exists for the node");

        this.num_active++;

        return request_on_conn;
    }

    /***************************************************************************

        Registers the specified RequestOnConn instance as finished. This does
        not modify anything about the RequestOnConn or the set, but simply
        decrements the num_active counter.

        Params:
            request_on_conn = the RequestOnConn instance which has finished
            (passed purely for the sake of sanity checking)

    ***************************************************************************/

    public void finished ( RequestOnConn request_on_conn )
    in
    {
        if ( !this.is_all_nodes )
            assert(this.single_node == request_on_conn);
    }
    out
    {
        if ( !this.is_all_nodes )
            assert(this.num_active == 0);
    }
    body
    {
        this.num_active--;
    }

    /***************************************************************************

        Clears this instance, including recycling all owned RequestOnConn
        instances via the provided recycle() delegate.

        Params:
            recycle = the delegate to call to recycle each RequestOnConn in the
            set

    ***************************************************************************/

    public void reset ( void delegate ( RequestOnConn ) recycle )
    in
    {
        assert(this.num_active == 0);
    }
    body
    {
        if ( this.is_all_nodes )
        {
            foreach ( request_on_conn; this.all_nodes )
            {
                this.all_nodes.remove(request_on_conn);
                recycle(request_on_conn);
            }
        }
        else
        {
            recycle(this.single_node);
        }

        this.is_all_nodes = false;
        this.single_node = this.single_node.init;
    }
}
