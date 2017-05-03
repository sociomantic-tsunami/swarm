/*******************************************************************************

    Super simplistic storage implementation of the example node.

    Copyright:
        Copyright (c) 2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module test.neo.node.Storage;

import ocean.transition;

public class Storage
{
    /// Values are simply stored in an associative array, indexed by key.
    public mstring[hash_t] map;
}
