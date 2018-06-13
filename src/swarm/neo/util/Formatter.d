/*******************************************************************************

    Wrapper around Ocean's ocean.text.convert.Formatter.sformat used to
    avoid usage of the deprecated overload that accepts a sink returning
    size_t in case overload accepting sink returning void is present (since
    ocean v2.8.

    This module could be removed and all code reverted to simply use
    ocean's Formatter in the next major.

    Copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.neo.util.Formatter;

import ocean.transition;
import ocean.core.VersionCheck;
import Formatter = ocean.text.convert.Formatter;

static if (hasFeaturesFrom!("ocean", 2, 8))
{
    /***************************************************************************

        Send the processed (formatted) input into a sink

        Params:
            sink    = A delegate that will be called, possibly multiple
                        times, with a portion of the result string
            fmt     = Format string to use
            args    = Variadic arguments to format according to fmt

        Returns:
            If formatting was successful, returns `true`, `false` otherwise.

    ***************************************************************************/

    public bool sformat (Args...) (
            scope void delegate ( cstring chunk) sink,
            cstring fmt, Args args )
    {
        return Formatter.sformat(sink, fmt, args);
    }
}
else
{
    /***************************************************************************

        Send the processed (formatted) input into a sink

        Params:
            sink    = A delegate that will be called, possibly multiple
                        times, with a portion of the result string
            fmt     = Format string to use
            args    = Variadic arguments to format according to fmt

        Returns:
            If formatting was successful, returns `true`, `false` otherwise.

    ***************************************************************************/

    public bool sformat (Args...) (
            scope void delegate ( cstring chunk) sink,
            cstring fmt, Args args )
    {
        return Formatter.sformat(
            ( cstring chunk )
            {
                sink(chunk);
                return chunk.length;
            },
            fmt, args);
    }
}
