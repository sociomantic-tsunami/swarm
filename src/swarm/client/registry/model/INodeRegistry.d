/*******************************************************************************

    Connection registry interface.

    Describes a registry of node connections to be kept by a client, with
    methods to add nodes to the registry and to assign requests to one or more
    of the registered nodes.

    copyright:      Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.registry.model.INodeRegistry;



/*******************************************************************************

    Imports

*******************************************************************************/

import swarm.client.registry.model.INodeRegistryInfo;

import swarm.client.request.params.IRequestParams;

import ocean.transition;


public interface INodeRegistry : INodeRegistryInfo
{
    /***************************************************************************

        Local type redefinitions.

    ***************************************************************************/

    alias .IRequestParams IRequestParams;


    /***************************************************************************

        Alias for a request assignment error delegate.

    ***************************************************************************/

    alias void delegate ( IRequestParams, Exception ) AssignErrorDg;


    /***************************************************************************

        Adds a node connection to the registry.

        Params:
            address = node address
            port = node service port

        Returns:
            this instance

        Throws:
            exception if the node already exists in the registry

    ***************************************************************************/

    void add ( mstring address, ushort port );


    /***************************************************************************

        Adds a request to one or more nodes. If the request specified in the
        provided params should be sent to all nodes simultaneously, then it is
        added to all nodes in the registry. Otherwise, the abstract method
        getResponsiblePool() is called to determine which node the request
        should be added to.

        Params:
            params = request parameters
            error_dg = delegate to be called if an exception is thrown while
                assigning a request. This delegate may be called multiple times
                for requests which make multiple assignments (to more than one
                node, for example)

        Returns:
            this instance

    ***************************************************************************/

    void assign ( IRequestParams request, AssignErrorDg error_dg );


    /***************************************************************************

        Determines whether the given request params describe a request which
        should be sent to all nodes simultaneously.

        Params:
            params = request parameters

        Returns:
            true if the request should be added to all nodes

    ***************************************************************************/

    bool allNodesRequest ( IRequestParams request );
}
