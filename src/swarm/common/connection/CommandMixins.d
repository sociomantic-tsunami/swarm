/*******************************************************************************

    Mixins for command code handling in connection handlers.

    copyright:      Copyright (c) 2012-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.common.connection.CommandMixins;



/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.core.Enum;

import ocean.transition;
import ocean.core.Traits: ctfe_i2a;


/*******************************************************************************

    Template to mix-in switch cases to call the handler methods for
    individual commands, according to the code read from the client.

    Template params:
        T = enum class (implementing IEnum) containing the commands to be
            handled
        i = recursion counter

*******************************************************************************/

public template CommandCases ( T : IEnum, size_t i = 0 )
{
    static if ( i == T._internal_names.length )
    {
        const istring CommandCases = "";
    }
    else
    {
        const istring CommandCases = "case " ~  ctfe_i2a(T._internal_values[i]) ~
            ": this.handle" ~ T._internal_names[i] ~ "(); break;" ~
            CommandCases!(T, i + 1);
    }
}

/*******************************************************************************

    Template to mix-in protected abstract methods to handle individual
    commands.

    Template params:
        T = enum class (implementing IEnum) containing the commands to be
            handled
        i = recursion counter

*******************************************************************************/

public template CommandMethods ( T : IEnum, size_t i = 0 )
{
    static if ( i == T._internal_names.length )
    {
        const istring CommandMethods = "";
    }
    else
    {
        const istring CommandMethods =
            "abstract protected void handle" ~ T._internal_names[i] ~ "();" ~
            CommandMethods!(T, i + 1);
    }
}

unittest
{
    static class Enum : IEnum
    {
        mixin EnumBase!([
            "A"[]:1,
            "B":2
       ]);
    }

    static class Test
    {
        mixin (CommandMethods!(Enum));

        void foo ()
        {            
            switch (2)
            {
                mixin (CommandCases!(Enum));

                default:
                    assert(false);
            }
        }
    }
}
