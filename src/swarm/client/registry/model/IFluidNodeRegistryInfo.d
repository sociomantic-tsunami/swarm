/*******************************************************************************

    Information interface to a fluid connection registry (set of pools of
    connections to nodes).

    Version:        2014-02-14: Initial release

    Authors:        Gavin Norman

    Provides read-only methods for informational purposes. Extends the basic
    INodeRegistryInfo interface with the following:
        * A method to get the number of disabled nodes.
        * A method to get the fraction of disabled nodes.
        * A method to return an iterator over disabled nodes.

    Copyright:      Copyright (c) 2014-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.registry.model.IFluidNodeRegistryInfo;



/*******************************************************************************

    Imports

*******************************************************************************/

import swarm.Const : NodeItem;

import swarm.client.registry.model.INodeRegistryInfo;

import swarm.client.connection.model.INodeConnectionPoolInfo;



public interface IFluidNodeRegistryInfo : INodeRegistryInfo
{
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


    /***************************************************************************

        Interface to an iterator over the set of disabled nodes

    ***************************************************************************/

    interface IDisabledIterator
    {
        /***********************************************************************

            opApply iterator over the address/port of disabled nodes and the
            informational interface to the associated pool of connections.

        ***********************************************************************/

        int opApply ( int delegate ( ref NodeItem,
            ref INodeConnectionPoolInfo ) dg );
    }


    /***************************************************************************

        Gets an iterator over the set of disabled nodes. The iterator is passed
        to the provided delegate. (The method has been implemented in this way,
        rather than simply returning an iterator instance, so that the iterator
        may be implemented as a scope class, which cannot be returned.)

        Params:
            dg = delegate to which iterator will be passed

    ***************************************************************************/

    void disabled_nodes ( void delegate ( IDisabledIterator ) dg );
}

