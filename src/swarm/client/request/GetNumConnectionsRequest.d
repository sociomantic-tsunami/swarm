/*******************************************************************************

    Asynchronously/Selector managed GetNumConnections request class

    Processes the node's output after a GetNumConnections command, and forwards
    the received data to the provided output delegate.

    copyright:      Copyright (c) 2014-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.request.GetNumConnectionsRequest;



/*******************************************************************************

    Imports

*******************************************************************************/

import swarm.client.request.model.IRequest;

import swarm.Const : ICommandCodes;



/*******************************************************************************

    Template for GetNumConnectionsRequest classes

    Template Params:
        Base = request base class from which to derive this request
        Resources = type of resources instance passed to ctor
        Cmd = code of command

*******************************************************************************/

public scope class GetNumConnectionsRequestTemplate ( Base : IRequest, Resources,
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

    override protected void sendRequestData_ ( )
    {
    }


    /***************************************************************************

        Handles a request once the request data has been sent and a valid status
        has been received from the node.

    ***************************************************************************/

    override protected void handle__ ( )
    {
        ushort port;
        size_t connections;

        this.reader.readArray(*this.resources.address_buffer);
        this.reader.read(port);
        this.reader.read(connections);

        auto output = this.params.io_item.get_num_connections();

        // TODO: note that we do not forward the address / port read from node,
        // instead using what is registered in the client to avoid mismatches.
        // The protocol should be changed to not send the addr/port.
        output(this.params.context, this.resources.conn_pool_info.address,
            this.resources.conn_pool_info.port, connections);
    }
}

