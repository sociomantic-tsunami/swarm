/*******************************************************************************

    Asynchronously/Selector managed RemoveChannel request class

    copyright:      Copyright (c) 2014-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.request.RemoveChannelRequest;



/*******************************************************************************

    Imports

*******************************************************************************/

import swarm.client.request.model.IRequest;

import swarm.Const : ICommandCodes;



/*******************************************************************************

    Template for RemoveChannelRequest classes

    Template Params:
        Base = request base class from which to derive this request
        Resources = type of resources instance passed to ctor
        Cmd = code of command

*******************************************************************************/

public scope class RemoveChannelRequestTemplate ( Base : IRequest, Resources,
    ICommandCodes.Value Cmd ) : Base
{
    /***************************************************************************

        Constructor

        Params:
            reader = FiberSelectReader instance to use for read requests
            writer = FiberSelectWriter instance to use for write requests
            resources = shared resources which might be required by the request

    ***************************************************************************/

    public this ( FiberSelectReader reader, FiberSelectWriter writer,
        Resources resources )
    {
        super(reader, writer, resources);
    }


    /***************************************************************************

        Sends the node any data required by the request.

    ***************************************************************************/

    override protected void sendRequestData__ ( )
    {
    }


    /***************************************************************************

        Handles a request once the request data has been sent and a valid status
        has been received from the node.

    ***************************************************************************/

    override protected void handle__ ( )
    {
    }
}

