/*******************************************************************************

    Credentials basic definitions and helpers

    copyright: Copyright (c) 2016-2017 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.neo.authentication.Credentials;

import Client = swarm.neo.authentication.ClientCredentials;

import core.stdc.ctype: isgraph;
import ocean.meta.types.Qualifiers;

/*******************************************************************************

    Limits for the length of credentials strings and files.

*******************************************************************************/

public enum LengthLimit: size_t
{
    /// The maximum allowed length of a client name.
    Name = 100,

    /// The maximum allowed size of a file containing client credentials
    /// (name/key pairs) in bytes.
    File = 10_000_000
}

/*******************************************************************************

    Scans name for non-graph characters.

    Params:
        name = input client name

    Returns:
        name.length minus the index of the first non-graph character found
        or 0 if all characters in name are graph characters.

*******************************************************************************/

public size_t validateNameCharacters ( cstring name )
{
    foreach (i, c; name)
    {
        if (!isgraph(c))
            return name.length - i;
    }

    return 0;
}
