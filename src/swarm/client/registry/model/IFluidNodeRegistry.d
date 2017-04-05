/*******************************************************************************

    Version:        2014-01-21: Initial release

    Authors:        Gavin Norman

    Extends INodeRegistry with methods to remove, disable and re-enable nodes.

    Copyright:      Copyright (c) 2014-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.registry.model.IFluidNodeRegistry;



/*******************************************************************************

    Imports

*******************************************************************************/

import swarm.client.registry.model.INodeRegistry;
import swarm.client.registry.model.IFluidNodeRegistryInfo;

import ocean.text.convert.Format;
import ocean.transition;



public interface IFluidNodeRegistry : INodeRegistry, IFluidNodeRegistryInfo
{
    /***************************************************************************

        Removes a node connection from the registry.

        Params:
            address = node address
            port = node service port

        Throws:
            exception if the node does not exist in the registry

    ***************************************************************************/

    void remove ( mstring address, ushort port );


    /***************************************************************************

        Disables a node connection in the registry.

        Params:
            address = node address
            port = node service port

        Throws:
            exception if the node does not exist in the registry

    ***************************************************************************/

    void disable ( mstring address, ushort port );


    /***************************************************************************

        Enables a node connection in the registry.

        Params:
            address = node address
            port = node service port

        Throws:
            exception if the node does not exist in the registry

    ***************************************************************************/

    void enable ( mstring address, ushort port );


    /***************************************************************************

        Returns:
            the number of nodes which have been disabled

    ***************************************************************************/

    size_t num_disabled ( );


    /***************************************************************************

        Returns:
            the fraction of nodes which have been disabled

    ***************************************************************************/

    float disabled_fraction ( );
}
