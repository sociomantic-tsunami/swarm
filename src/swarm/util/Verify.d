/*******************************************************************************

    Helper module to use `verify` from ocean v3.4 instead of `assert`, even if
    the ocean submodule is at a version that does not include
    `ocean.core.Verify`. This is to allow for writing new swarm code that can be
    safely merged into v5.

    Copyright: Copyright (c) 2018 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.
        Alternatively, this file may be distributed under the terms of the Tango
        3-Clause BSD License (see LICENSE_BSD.txt for details).

*******************************************************************************/

module swarm.util.Verify;

import ocean.core.VersionCheck;

static if (hasFeaturesFrom!("ocean", 3, 4))
    public import ocean.core.Verify;
else:

import ocean.meta.types.Qualifiers;

/*******************************************************************************

    Verifies that certain condition is met.

    Params:
        ok = boolean condition to check
        msg = optional exception message

    Throws:
        SanityException if `ok` condition is `false`.

*******************************************************************************/

public void verify ( bool ok, lazy istring msg = "",
    istring file = __FILE__, int line = __LINE__ )
{
    static SanityException exc;

    if (exc is null)
        exc = new SanityException("");

    if (!ok)
    {
        exc.file = file;
        exc.line = line;
        exc.msg = msg;

        throw exc;
    }
}

unittest
{
    try
    {
        verify(false);
    }
    catch (SanityException e) { }

    verify(true);
}

/*******************************************************************************

    Indicates some internal sanity violation in the app, essentially a less
    fatal version of `AssertError`.

*******************************************************************************/

public class SanityException : Exception
{
    public this ( istring msg, istring file = __FILE__, int line = __LINE__ )
    {
        super(msg, file, line);
    }
}
