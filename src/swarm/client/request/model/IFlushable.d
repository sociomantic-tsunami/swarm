/*******************************************************************************

    Interfaces for:
        * Something which can be flushed (IFlushable).
        * A set of things which can be flushed (IFlushables).

    copyright:      Copyright (c) 2012-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.request.model.IFlushable;



/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.util.container.map.Set;



/*******************************************************************************

    Interface to something that can be flushed.

*******************************************************************************/

public interface IFlushable
{
    void flush ( );
}


/*******************************************************************************

    Interface to a collection of things that can be flushed.

*******************************************************************************/

public interface IFlushables
{
    /***************************************************************************

        Adds an IFlushable to the set.

        This method is aliased as opAddAssign (+=).

        Params:
            flushable = flushable to add to set

    ***************************************************************************/

    void register ( IFlushable flushable );

    alias register opAddAssign;


    /***************************************************************************

        Removes an IFlushable from the set.

        This method is aliased as opSubAssign (-=).

        Params:
            flushable = flushable to remove from set

    ***************************************************************************/

    void unregister ( IFlushable flushable );

    alias unregister opSubAssign;


    /***************************************************************************

        Flushes all registered IFlushables.

    ***************************************************************************/

    void flush ( );
}

