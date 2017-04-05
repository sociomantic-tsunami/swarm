/*******************************************************************************

    Information interface for storage channel in a node

    copyright:      Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.node.storage.model.IStorageEngineInfo;

import ocean.transition;

public interface IStorageEngineInfo
{
    /***************************************************************************

        Returns:
            the identifier string of this channel

    ***************************************************************************/

    public cstring id ( );


    /***************************************************************************

        Returns:
            number of records stored

    ***************************************************************************/

    public ulong num_records ( );


    /***************************************************************************

        Returns:
            number of bytes stored

    ***************************************************************************/

    public ulong num_bytes ( );
}

