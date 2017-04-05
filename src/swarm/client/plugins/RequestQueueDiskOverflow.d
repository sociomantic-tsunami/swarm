/*******************************************************************************

    Swarm client request queue disk overflow plugin.

    Client plugin which modifies the behaviour of a client so that any requests
    which cannot fit in the request queue for the intended node will instead be
    pushed into a disk-based queue.

    The code inside the Extension template (see below) is mixed into the client.

    copyright:      Copyright (c) 2012-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.plugins.RequestQueueDiskOverflow;



/*******************************************************************************

    Imports

*******************************************************************************/

import swarm.client.connection.RequestOverflow;

import ocean.transition;

/*******************************************************************************

    Request queue disk overflow plugin for swarm client. (To be used with the
    ExtensibleXClient class templates.)

    The plugin works using an interface which provides two methods:
        1. store(), which accepts an IRequestParams and should return a
           serialized ubyte[] which will be stored on disk and used to restore
           the request at some later point.
        2. restore(), which accepts a ubyte[] containing a serialized request
           previously procuded by store(), and should extract and re-assign the
           request to the client.

*******************************************************************************/

public class RequestQueueDiskOverflow
{
    /***************************************************************************

        Disk overflow for request params.

    ***************************************************************************/

    private alias DiskOverflow Overflow;

    public Overflow disk_overflow;


    /***************************************************************************

        Alias for the request store interface, providing the store() and
        restore() methods.

    ***************************************************************************/

    public alias Overflow.IRequestStore IRequestStore;


    /***************************************************************************

        Constructor.

        Params:
            request_store = interface providing store() and restore() methods
            file_path = path of overflow file
            open_existing = do we reopen any existing file queues

    ***************************************************************************/

    public this ( IRequestStore request_store, cstring file_path,
        bool open_existing = false )
    {
        this.disk_overflow = new Overflow(request_store, file_path,
            open_existing);
    }


    /***************************************************************************

        Code to be mixed into the client.

    ***************************************************************************/

    template Extension ( istring instance )
    {
        /***********************************************************************

            Overrides the default requestOverflow() method, which provides a
            void overflow handler. Instead returns a disk overflow handler.

            Returns:
                overflow handler instance

        ***********************************************************************/

        override protected IRequestOverflow requestOverflow ( )
        {
            return mixin(instance).disk_overflow;
        }


        /***********************************************************************

            Method to enable and disable the pop function of the disk overflow

            Params:
                enable_pop = enable or disable the pop

        ***********************************************************************/

        public void enablePop ( bool enable_pop )
        {
            mixin(instance).disk_overflow.enablePop(enable_pop);
        }
    }
}

