/*******************************************************************************

    Storage channels base class

    Base class for a set of storage channels with the following features:
        * Acts as a container for a set of zero or more storage channels
          (aka storage engines) of a specific type, each with a string
          identifier.
        * Has methods to create, get and remove channels by identifier.
        * Has a size limit which the combined size of all channels must stay
          beneath.
        * Can be shutdown, closing all channels.

    copyright:      Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.node.storage.model.IStorageChannels;



/*******************************************************************************

    Imports

*******************************************************************************/

import swarm.node.storage.model.IStorageEngine;

import ocean.util.container.map.Map;

import ocean.util.container.pool.ObjectPool;

import ocean.core.ExceptionDefinitions;

import ocean.util.log.Log;

import ocean.transition;

/*******************************************************************************

    Static module logger

*******************************************************************************/

static private Logger log;
static this ( )
{
    log = Log.lookup("swarm.node.storage.model.IStorageChannels");
}



/*******************************************************************************

    IStorageChannels interface

*******************************************************************************/

abstract public class IStorageChannelsTemplate ( Storage : IStorageEngine )
{
    /***************************************************************************

        Pool of storage engines

    ***************************************************************************/

    private ObjectPool!(Storage) channel_pool;


    /***************************************************************************

        Storage engine channel registry

    ***************************************************************************/

    private alias StandardKeyHashingMap!(Storage, cstring) Channels;

    private Channels channels;


    /***************************************************************************

        Total size limit of all channels (0 = no size limit)

    ***************************************************************************/

    private ulong size_limit;


    /***************************************************************************

        Flag set to true if the creation of a channel (by the create_() method)
        fails due to an OutOfMemory exception. In this case further requests to
        create new channels will be ignored, in order to prevent the case where
        the node gets into the state where it's constantly attempting and
        failing to create a new channel.

    ***************************************************************************/

    private bool no_more_channels;


    /***************************************************************************

        Constructor.

    ***************************************************************************/

    public this ( ulong size_limit )
    {
        this.size_limit = size_limit;

        this.channel_pool = new ObjectPool!(Storage);

        const channels_estimate = 100; // TODO: configurable?
        this.channels = new Channels(channels_estimate);
    }


    /***************************************************************************

        Returns:
             string identifying the type of the storage engine

    ***************************************************************************/

    abstract public cstring type ( );


    /***************************************************************************

        Looks up channel_id in registered channels.

        Params:
            channel_id = channel identifier string to lookup

        Returns:
            true if the channel was found or false otherwise

    ***************************************************************************/

    public Storage* opIn_r ( cstring channel_id )
    {
        return channel_id in this.channels;
    }


    /***************************************************************************

        "foreach" iteration over channels currently in registry

    ***************************************************************************/

    public int opApply ( int delegate ( ref Storage channel ) dg )
    {
        int result = 0;

        foreach (name, channel; this.channels)
        {
            result = dg(channel);

            if (result) break;
        }

        return result;
    }


    /***************************************************************************

        Returns:
            number of channels in the registry

    ***************************************************************************/

    public size_t length ( )
    {
        return this.channels.bucket_info.length;
    }


    /***************************************************************************

        If the named channel exists, then a reference to it is returned. If it
        does not exist, then the channel is created and a reference to it
        returned.

        Params:
            channel_id = channel identifier string

        Returns:
            named channel (either pre-existing or newly created), or null if the
            creation of a new channel failed (probably due to out of memory)

    ***************************************************************************/

    public Storage getCreate ( cstring channel_id )
    {
        auto channel = channel_id in this.channels;
        return channel is null ? this.create(channel_id) : *channel;
    }


    /***************************************************************************

        Removes channel with identifier string channel_id from the registered
        channels. All records in the channel are deleted.

        Params:
            channel_id = identifier string of channel to remove

    ***************************************************************************/

    public void remove ( cstring channel_id )
    {
        auto channel = channel_id in this.channels;
        if ( channel !is null )
        {
            channel.clear();
            channel.close();
            this.channel_pool.recycle(*channel);

            // Remove from the array map last, as this makes the pointer invalid
            this.channels.remove(channel_id);
        }
    }


    /***************************************************************************

        Performs a graceful shutdown, closing all channels.

    ***************************************************************************/

    final public void shutdown ( )
    {
        this.shutdown_();

        foreach ( name, channel; this.channels )
        {
            channel.close();
        }

        this.channels.clear();
    }


    /***************************************************************************

        Called first thing when a shutdown is performed. Base class
        implementation does nothing, but derived classes can implement special
        behaviour at this point.

    ***************************************************************************/

    protected void shutdown_ ( )
    {
    }


    /***************************************************************************

        Tells whether the size of all records in the storage channels, plus the
        optional extra size specified, exceed the defined size limit.

        Note: this method only checks the size of the bytes in the storage
        channel(s), it *does not* guarantee that the storage engine will
        successfully be able to push the additional data -- the only way is to
        do the push and check the push method's return value.

        Params:
            additional_size = additional data size to test whether it'd fit

        Returns:
            true if size of all records (plus additional size) is less than the
            defined size limit for the whole node

        TODO: the concept of a size limit is particular to certain types of
        node. Other nodes may not require it, so it should be removed from the
        base class.

    ***************************************************************************/

    public bool sizeLimitOk ( size_t additional_size )
    {
        if ( this.size_limit == 0 ) return true;

        ulong total_bytes;

        foreach ( name, storage; this.channels )
        {
            if ( storage !is null )
            {
                total_bytes += storage.num_bytes;
            }
        }

        return total_bytes + additional_size <= this.size_limit;
    }


    /***************************************************************************

        Creates a new Storage instance and adds it to the channels
        registry with identifier string channel_id. Called by the public
        getCreate() method, above, but may also be called by sub-classes (for
        example when loading saved channels upon construction).

        Params:
            channel_id = channel identifier string

        Returns:
            reference to newly created channel instance, or null if the creation
            of a new channel failed (probably due to out of memory)

    ***************************************************************************/

    protected Storage create ( cstring channel_id )
    in
    {
        assert(!(channel_id in this.channels), typeof(this).stringof ~ ".create: channel '" ~ channel_id ~ "' already exists!");
    }
    body
    {
        if ( !this.no_more_channels )
        {
            try
            {
                auto channel = this.channel_pool.get(this.create_(channel_id));
                channel.initialise(channel_id);
                this.channels[channel.id] = channel;

                assert(channel.id == channel_id, typeof(this).stringof ~
                    ".create: channel name mismatch - '" ~ channel_id ~
                    " vs '" ~ channel.id ~ "'");

                assert(channel_id in this.channels, typeof(this).stringof ~
                    ".create: channel '" ~ channel_id ~ "' not in map after creation!");

                return channel;
            }
            catch ( OutOfMemoryException e )
            {
                log.error("Node out of memory -- failed to create requested channel '{}'", channel_id);
                this.no_more_channels = true;
            }
        }

        return null;
    }


    /***************************************************************************

        Creates a new storage engine with the given name.

        Params:
            channel_id = channel identifier string

        Returns:
            new storage engine

    ***************************************************************************/

    abstract protected Storage create_ ( cstring channel_id );
}

