/*******************************************************************************

    Copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.util.FieldSizeSum;

/*******************************************************************************

    Calculates the sum of the .sizeof values of S.tupleof[i .. $].

*******************************************************************************/

template FieldSizeSum ( S, size_t i = 0 )
{
    static if (i < S.tupleof.length)
    {
        const FieldSizeSum = S.tupleof[i].sizeof + FieldSizeSum!(S, i + 1);
    }
    else
    {
        const size_t FieldSizeSum = 0;
    }
}
