/*******************************************************************************

    Storage engine base class.

    Base class for a storage engine with the following features:
        * Identified by a string (aka the channel name)
        * Has a size which can be read in terms of the number of record stored
          and the number of bytes stored.
        * Can be emtpied and closed.

    copyright:      Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.node.storage.model.IStorageEngine;



/*******************************************************************************

    Imports

*******************************************************************************/

import swarm.node.storage.model.IStorageEngineInfo;

import ocean.core.Array;

import ocean.util.container.pool.model.IResettable;

import ocean.transition;

abstract public class IStorageEngine : IStorageEngineInfo, Resettable
{
    /***************************************************************************

        Index of this instance in the object pool in IStorageChannels.

    ***************************************************************************/

    public size_t object_pool_index;


    /***************************************************************************

        Identifier string of channel.

    ***************************************************************************/

    protected mstring id_;


    /***************************************************************************

        Constructor. Copies the passed channel id and calls the initialise()
        method.

        Params:
            id = identifier string of channel

    ***************************************************************************/

    public this ( cstring id )
    {
        this.initialise(id);
    }


    /***************************************************************************

        Initialiser. Called from the constructor, as well as when a storage
        engine is re-used from the pool.

    ***************************************************************************/

    public void initialise ( cstring id )
    {
        this.id_.copy(id);
    }


    /***************************************************************************

        Reset method, called when the storage engine is returned to the pool in
        IStorageChannels. The base class implementation does nothing, but it can
        be overridden by sub-classes which need to implement special cleanup
        behaviour.

    ***************************************************************************/

    public void reset ( )
    {
    }


    /***************************************************************************

        Flushes write buffers of stream connections.

    ***************************************************************************/

    public void flush ( )
    {
    }


    /***************************************************************************

        Removes all records from the storage engine

        Returns:
            this instance

     **************************************************************************/

    abstract public typeof(this) clear ( );


    /***************************************************************************

        Closes the storage engine.

        Returns:
            this instance

     **************************************************************************/

    abstract public typeof(this) close ( );


    /***************************************************************************

        Returns:
            the identifier string of this storage engine

     **************************************************************************/

    public cstring id ( )
    {
        return this.id_;
    }
}

