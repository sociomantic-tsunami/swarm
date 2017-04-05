/*******************************************************************************

    A set of flushable things (IFlushables). IFlushables can be added to and
    removed from the set. The flush() method flushes all registered IFlushables.

    copyright:      Copyright (c) 2012-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.registry.FlushableSet;



/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.util.container.map.Set;

import swarm.client.request.model.IFlushable;



/*******************************************************************************

    Set of flushable things.

*******************************************************************************/

public class FlushableSet : Set!(IFlushable), IFlushables
{
    /***************************************************************************

        Constructor, sets the number of buckets to n * load_factor

        Params:
            n = expected number of elements
            load_factor = load factor

    ***************************************************************************/

    public this ( size_t n, float load_factor = 0.75 )
    {
        super(n, load_factor);
    }


    /***************************************************************************

        Adds an IFlushable to the set.

        This method is aliased as opAddAssign (+=).

        Params:
            flushable = flushable to add to set

    ***************************************************************************/

    public void register ( IFlushable flushable )
    {
        assert(!(flushable in this), "IFlushable interface already in set");
        this.put(flushable);
    }


    /***************************************************************************

        Removes an IFlushable from the set.

        This method is aliased as opSubAssign (-=).

        Params:
            flushable = flushable to remove from set

    ***************************************************************************/

    public void unregister ( IFlushable flushable )
    {
        assert(flushable in this, "IFlushable interface not in set");
        this.remove(flushable);
    }


    /***************************************************************************

        Flushes all registered IFlushables in the set.

    ***************************************************************************/

    public void flush ( )
    {
        foreach ( flushable; this )
        {
            flushable.flush();
        }
    }


    /***************************************************************************

        Implementation of method required by Set.

        Provides a hash for an IFlushable.

        Params:
            flushable = IFlushable to hash

        Returns:
            hash value for IFlushable

    ***************************************************************************/

    override public hash_t toHash ( IFlushable flushable )
    {
        return cast(hash_t)cast(void*)flushable;
    }
}

