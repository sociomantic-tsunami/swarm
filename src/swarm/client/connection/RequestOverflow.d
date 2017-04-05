/*******************************************************************************

    Request queue overflow handlers.

    Request queue overflow handling infrastructure to decide what to do when a
    client's request queue is full.

    An interface for a generic request overflow handler is defined, followed by
    two implementations, one which throws an exception upon overflow, and one
    which writes overflowed requests to disk.

    The request overflow interface is conceived as a set of queues with a
    unique queue for every node the client is connected to. The request
    overflow provides methods to push and pop requests for specific nodes,
    to get the total number of overflow requests, and to enable pops for the
    nodes.

    A file queue for a node is created and added to a map the first time any
    request (including read-only, informational requests like calling the
    length() method) is made to it.

    If the open_existing flag is set to true for a disk queue then the calling
    application MUST call enablePop(true) when it is ready to pop records from
    the queues. The idea behind enablePop is that an application can connect
    to a server cluster with the overflow and complete any other setup it
    requires before the records start being popped. So the process would be:

    1) Application connects to the node and the saved records are read in to the
       file queue.
    2) Application completes any other setup or initialisation it requires.
    3) Application calls enablePop when it is ready to receive records.

    copyright:      Copyright (c) 2012-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.connection.RequestOverflow;



/*******************************************************************************

    Imports.

*******************************************************************************/

import swarm.client.request.params.IRequestParams;

import swarm.Const;

import ocean.util.container.queue.FlexibleFileQueue;

import ocean.transition;

import Integer = ocean.text.convert.Integer_tango;

debug import ocean.io.Stdout;



/*******************************************************************************

    Request overflow interface.

    Template params:
        Params = type of request parameters

*******************************************************************************/

public interface IRequestOverflow
{
    /***************************************************************************

        Local type redefinition.

    ***************************************************************************/

    public alias .IRequestParams IRequestParams;


    /***************************************************************************

        Pushes a request into the overflow. Called when a request was attempted
        to be pushed into a node's request queue, but the queue was full.

        Params:
            params = parameters for request which has overflowed from the queue
            node = the node to push to

        Returns:
            true if the params were pushed to the overflow, false if something
            went wrong

    ***************************************************************************/

    public bool push ( IRequestParams params, NodeItem node );


    /***************************************************************************

        Pops and handles a node's request from the overflow.

        Params:
            node = the node to pop from

        Returns:
            true if a request was popped

    ***************************************************************************/

    public bool pop ( NodeItem node );


    /***************************************************************************

        Check the length of the overflow queue for a particular node

        Params:
            node = the node to check the length of the overflow queue for

        Returns:
            the number of requests in the this nodes overflow overflow

    ***************************************************************************/

    public size_t length ( NodeItem node );


    /***************************************************************************

        Check the amount of data in the overflow queue for a particular node

        Params:
            node = the node to check the length of the overflow queue for

        Returns:
            the amount of data in the overflow queue for node.

    ***************************************************************************/

    public size_t used_space ( NodeItem node );


    /***************************************************************************

        Used to enable or disable whether the file queue can pop items

    ***************************************************************************/

    public void enablePop ( bool enable_pop );
}



/*******************************************************************************

    Void request overflow -- simply throws an exception upon overflow.

    Template params:
        Params = type of request parameters

*******************************************************************************/

public class VoidOverflow : IRequestOverflow
{
    /***************************************************************************

        Called when a request was attempted to be pushed into a node's request
        queue, but the queue was full. Always returns false, as the void
        overflow can never accept requests.

        Params:
            params = parameters for request which has overflowed from the queue
            node = the node to push to

        Returns:
            always false

    ***************************************************************************/

    public bool push ( IRequestParams params, NodeItem node )
    {
        return false;
    }


    /***************************************************************************

        Pops and handles a node's request from the overflow. Does nothing, as
        no requests are ever stored in the overflow.

        Params:
            node = the node to pop from

        Returns:
            always false (nothing popped)

    ***************************************************************************/

    public bool pop ( NodeItem node )
    {
        return false;
    }


    /***************************************************************************

        Returns:
            always 0, as no requests are ever stored in the overflow.

    ***************************************************************************/

    public size_t length ( NodeItem node )
    {
        return 0;
    }


    /***************************************************************************

        Check the amount of data in the overflow queue for a particular node

        Params:
            node = the node to check the length of the overflow queue for

        Returns:
            the amount of data in the overflow queue for node.

    ***************************************************************************/

    public size_t used_space ( NodeItem node )
    {
        return 0;
    }


    /***************************************************************************

        Used to enable or disable whether the file queue can pop items

    ***************************************************************************/

    public void enablePop ( bool enable_pop ){}
}



/*******************************************************************************

    Disk request overflow -- stores and restores requests from an unbounded disk
    backup.

    Template params:
        Params = type of request parameters

*******************************************************************************/

public class DiskOverflow : IRequestOverflow
{
    /***************************************************************************

        Interface to a request store, providing methods to store (= serialize)
        and restore (= deserialize and re-assign) overflowed requests.

    ***************************************************************************/

    public interface IRequestStore
    {
        /***********************************************************************

            Serializes an overflowed request. The slice which store() returns is
            passed into the push() method of the disk queue, which implements a
            blocking write of the data to the disk. Thus the class implementing
            store() does not need to worry about the lifetime of the slice.

            Params:
                params = parameters of request

            Returns:
                serialized ubyte[] which can be deserialized to restore the
                request

        ***********************************************************************/

        public ubyte[] store ( IRequestParams params );


        /***********************************************************************

            Deserializes and re-assigns an overflowed request.

            Params:
                stored = ubyte[] containing a serialized request

        ***********************************************************************/

        public void restore ( ubyte[] stored );
    }


    /***************************************************************************

        Request store interface, passed into constructor.

    ***************************************************************************/

    private IRequestStore request;


    /***************************************************************************

        File queues where overflowed requests are stored. There is one file
        queue per node.

    ***************************************************************************/

    private FlexibleFileQueue[hash_t] disk_queues;


    /***************************************************************************

        Do we use the file queue that can re-open existing files

    ***************************************************************************/

    private Const!(bool) open_existing;


    /***************************************************************************

        Is the pop enabled for the file queues

    ***************************************************************************/

    private bool enable_pop;


    /***************************************************************************

        Base file path for the file queues. They have the naming format of
        basename.ipaddress.port

    ***************************************************************************/

    private cstring file_path;


    /***************************************************************************

        Constructor. If the open_existing flag is set to true then the calling
        application MUST call enablePop(true) when it is ready to pop records
        from the queues.

        Params:
            request = request store interface
            file_path = path of overflow file
            open_existing = do we reopen any existing file queues

    ***************************************************************************/

    public this ( IRequestStore request, cstring file_path,
        bool open_existing = false )
    {
        this.request = request;
        this.open_existing = open_existing;
        this.enable_pop = !this.open_existing;
        this.file_path = file_path.dup;
    }


    /***************************************************************************

        Pushes a request into the overflow. Called when a request was attempted
        to be pushed into a node's request queue, but the queue was full.

        Params:
            params = parameters for request which has overflowed from the queue
            node = the node to push to

        Returns:
            true, assuming that the disk based overflow is infinite

    ***************************************************************************/

    public bool push ( IRequestParams params, NodeItem node )
    {
        this.getFileQueue(node).push(this.request.store(params));
        return true;
    }


    /***************************************************************************

        Pops and handles a node's request from the overflow. Will only pop
        records from the queue if enable pop is set to true.

        Params:
            node = the node to pop from

        Returns:
            true if a request was popped

    ***************************************************************************/

    public bool pop ( NodeItem node )
    {
        if ( this.enable_pop )
        {
            auto popped = this.getFileQueue(node).pop;
            if ( popped !is null )
            {
                this.request.restore(popped);
                return true;
            }
        }
        return false;
    }


    /***************************************************************************

        Check the length of the overflow queue for a particular node

        Params:
            node = the node to check the length of the overflow queue for

        Returns:
            the number of requests in the this nodes overflow overflow

    ***************************************************************************/

    public size_t length ( NodeItem node )
    {
        return this.getFileQueue(node).length;
    }


    /***************************************************************************

        Check the amount of data in the overflow queue for a particular node

        Params:
            node = the node to check the length of the overflow queue for

        Returns:
            the amount of data in the overflow queue for node.

    ***************************************************************************/

    public size_t used_space ( NodeItem node )
    {
        return this.getFileQueue(node).used_space;
    }


    /***************************************************************************

        Used to enable or disable whether the file queues can pop items.

        Params:
            enable_pop = do we enable or disable the pop operation

    ***************************************************************************/

    public void enablePop ( bool enable_pop )
    {
        this.enable_pop = enable_pop;
    }


    /***************************************************************************

        Get the file queue for a particular node item as we have a seperate
        file queue for each one. If it has not been used before (ie it is null)
        the create it. If a file queue is created call the enable pop with the
        current setting to initialize it to the correct value.

        Params:
            node = the node info to get the file queue for

        Returns:
            the file queue for the node

    ***************************************************************************/

    private FlexibleFileQueue getFileQueue ( NodeItem node )
    out (queue)
    {
        assert (queue !is null, "Creation of FlexibleFileQueue failed");
    }
    body
    {
        auto queue = node.toHash in this.disk_queues;
        if ( queue is null )
        {
            auto new_queue = new FlexibleFileQueue(this.file_path ~ "." ~
                node.Address ~ "." ~ Integer.toString(node.Port),
                1024 * 1024, this.open_existing);
            this.disk_queues[node.toHash] = new_queue;
        }
        return this.disk_queues[node.toHash];
    }

    // unit test is located in separate top-level ./test hierarchy as it does I/O
}
