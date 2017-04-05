/*******************************************************************************

    Fiber-based abstract base class for node requests.

    Fiber-based implementation of a request handler in a node, with the
    following features:
        * Encapsulates a fiber select reader & writer, usable by derived
          classes.
        * Has a handle() method, called when a request should be processed. The
          handle() method reads all data sent by the client, checks whether the
          request is valid

    copyright:      Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.node.request.model.IRequest;



/*******************************************************************************

    Imports

*******************************************************************************/

import swarm.common.request.model.IFiberRequest;

import ocean.transition;

/*******************************************************************************

    Request base class template.

    Template params:
        Params = type to be passed upon handling of a request, should contain
            all information required to process the request

*******************************************************************************/

public abstract class IRequest : IFiberRequest
{
    /***************************************************************************

        Constructor

        Params:
            reader = FiberSelectReader instance to use for read requests
            writer = FiberSelectWriter instance to use for write requests

    ***************************************************************************/

    public this ( FiberSelectReader reader, FiberSelectWriter writer )
    {
        super(reader, writer);
    }


    /***************************************************************************

        Fiber method. Stores the request parameters and handles the request.

        1. Reads all data provided by the client (ensuring that the read buffer
           is cleared, even if an error occurs while handling the request).
        2. Calls the abstract handle_() method, to execute the request.
        3. Flushes the write buffer to ensure that all data required is sent to
           the client.

    ***************************************************************************/

    final public void handle ( )
    {
        this.readRequestData();

        this.handle_();

        super.writer.flush();
    }


    /***************************************************************************

        Formats a description of this command into the provided buffer.

        Params:
            dst = buffer to format description into

        Returns:
            description of command (slice of dst)

    ***************************************************************************/

    abstract public mstring description ( ref mstring dst );


    /***************************************************************************

        Reads any data from the client which is required for the request. If the
        request is invalid in some way (the channel name is invalid, or the
        command is not supported) then the command can be simply not executed,
        and all client data has been read, leaving the read buffer in a clean
        state ready for the next request.

    ***************************************************************************/

    abstract protected void readRequestData ( );


    /***************************************************************************

        Performs this request. (Fiber method, after command validity has been
        confirmed.)

    ***************************************************************************/

    abstract protected void handle_ ( );
}

