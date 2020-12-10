/*******************************************************************************

    Super simplistic storage implementation of the example node.

    Copyright:
        Copyright (c) 2017 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module integrationtest.neo.node.Storage;

import ocean.meta.types.Qualifiers;

public class Storage
{
    /// Values are simply stored in an associative array, indexed by key.
    public mstring[hash_t] map;
}
