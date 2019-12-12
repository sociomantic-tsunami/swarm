/*******************************************************************************

    Helper for setting up optional request arguments from a list of delegates,
    each handling arguments of a certain type, and the specified template-
    variadic arguments, forwarded from another function.

    Usage example:
        see documented unittest of setupOptionalArgs()

    copyright: Copyright (c) 2016-2017 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.neo.client.request_options.RequestOptions;

import ocean.transition;
import ocean.core.Tuple;

/*******************************************************************************

    Helper for setting up optional request arguments from a list of delegates,
    each handling arguments of a certain type, and the specified template-
    variadic arguments, forwarded from another function.

    Use this function as if it would be defined as

        `void setupOptionalArgs ( size_t n_args, T ... ) ( T args_and_dgs )`

    (See below for the purpose of `T1 arg`.)

     - For `n_args` pass the number of variadic arguments of your function.
     - For `args_and_dgs` pass the variadic arguments of your function, followed
       by the handler delegates.

    Each handler delegate is required to be a `void delegate(A)` where `A` can
    be any type. Multiple handlers of the same type are not allowed.
    The list of variadic arguments is iterated, looking for arguments of types
    accepted by one of the delegates. When an argument of a suitable type is
    found in the list of variadic arguments, it is passed to the corresponding
    delegate. If a variadic argument has a type that is not accepted by any of
    the handler delegates or multiple variadic arguments have the same type then
    a compile-time error is raised.

    The purpose of `T1 arg` is merely to work around a bug in DMD v1.077s17 and
    still in v1.081.2, which fails compiling if `n_args == 0`. DMD v1.076 and
    v2.072.1 don't fail. TODO: Remove `T1 arg` when the DMD bug is fixed.

    Params:
        n_args       = the number of arguments to handle
        arg1         = the first argument (ignored if `n_args == 0`)
        args_and_dgs = subsequent arguments, followed by handler delegates (or
                       only handler delegates if `n_args == 1`)

*******************************************************************************/

public void setupOptionalArgs ( size_t n_args, T1, T ... )
    ( T1 arg1, T args_and_dgs )
{
    static if (n_args)
    {
        static immutable n_args1 = n_args - 1;

        foreach (i, Handler; T[n_args1 .. $])
        {
            alias getHandlerArgument!(Handler, T[n_args1 .. $][0 .. i]) HandArg;

            static if (is(T1 == HandArg))
            {
                args_and_dgs[n_args1 + i](arg1);
            }
            else
            {
                foreach (j, Arg; T[0 .. n_args1])
                {
                    static if (is(Arg == HandArg))
                    {
                        args_and_dgs[n_args1 + i](args_and_dgs[j]);
                        break;
                    }
                }
            }
        }

        mixin(assertArgsHandled!(n_args, T1, T)());
    }
}

///
unittest
{
    // Struct containing an optional request timeout value.
    struct Timeout
    {
        uint ms;
    }

    // Struct containing an optional request context.
    struct Context
    {
        Object object;
    }

    // The arguments for the request. Would be passed, for example, to the
    // RequestCore template and stored in the working data buffer inside the
    // Request instance.
    struct RequestArgs
    {
        cstring channel; // mandatory
        uint timeout_ms; // optional
        Object context_object; // optional
    }


    // Example request assignment method. Assigns an imaginary request over a
    // specific channel, with varargs allowing optional settings to be
    // specified.
    static void assignRequest ( Options ... )
        ( cstring channel, Options options )
    {
        RequestArgs args;
        args.channel = channel;
        setupOptionalArgs!(options.length)(options,
            ( Timeout timeout )
            {
                args.timeout_ms = timeout.ms;
            },
            ( Context context )
            {
                args.context_object = context.object;
            }
        );
    }

    // Call the assign method, specifying some optional settings.
    assignRequest("test_channel", Timeout(23), Context(new Object));

    // Order doesn't matter
    assignRequest("test_channel", Context(new Object), Timeout(23));
}

/*******************************************************************************

    Template to strip the members of the given type from the variadic
    arguments. This should be used if the variadic arguments should be
    forwarded to another method, which accepts only a subset of the possible
    handlers, so the extra one should be removed prior to forwarding.

    Params:
        TypeToErase = type to erase from options
        options = Tuple to erase the members matching TypeToErase

    Returns:
        options without any member with type equal to TypeToErase

*******************************************************************************/

template eraseFromArgs (TypeToErase, options ...)
{
    static if (options.length > 0)
    {
        static if (is(typeof(options[0]) == TypeToErase))
        {
            alias options[1..$] eraseFromArgs;
        }
        else
        {
           alias Tuple!(options[0], eraseFromArgs!(TypeToErase, options[1..$]))
               eraseFromArgs;
        }
    }
    else
    {
        alias Tuple!() eraseFromArgs;
    }
}

unittest
{
    Tuple!(int, char, float) t;
    alias eraseFromArgs!(char, t) filtered;

    test!("==")(filtered.length, 2);
    test!("==")(is(typeof(filtered[0]) == int), true);
    test!("==")(is(typeof(filtered[1]) == float), true);
}

/*******************************************************************************

    Evaluates to the argument type of `Handler`. Ensures that `Handler` is a
    delegate with one argument returning `void` and none of `Handlers` has the
    same signature.

    Params:
        Handler  = the delegate type to return the argument type for
        Handlers = other types where none should have the same signature as
            `Handler`

    Returns:
        the argument type of `Handler`.

*******************************************************************************/

private template getHandlerArgument ( Handler, Handlers ... )
{
    static if (is(Handler Fn == delegate) &&
        is(Fn Args == function) && is (Fn Ret == return))
    {
        static assert(Args.length == 1 && is(Ret == void),
            "Handler delegates should accept one argument and return void");
        static if (Handlers.length)
        {
            // Note that delegate types with the same argument and return types
            // compare different if they have different D2 function attributes
            // so two delegates `D1` and `D2` need to be compared by deriving
            // the return type `R` and argument types `A` of of `D1` and check
            // if `is(D2 : R delegate(A))`.
            static assert(!is(Handlers[0] : void delegate(Args)),
                "Two handlers accept " ~ Args.stringof);
            alias getHandlerArgument!(Handler, Handlers[1 .. $])
                getHandlerArgument;
        }
        else
            alias Args[0] getHandlerArgument;
    }
    else
        static assert(false, "Handler argument is not a delegate");
}

/*******************************************************************************

    Verifies that for each argument type there is a handler and argument types
    are unique.

    Params:
        n_args = `ArgsAndHandlers[0 .. n_args]` are the argument types
        ArgsAndHandlers = the argument types followed by the handler delegate
            types

    Returns:
        an empty string if everything is correct or a "static assert(false);"
        string listing affected types in the message if there are duplicate
        argument types and/or an argument type is not handled.

*******************************************************************************/

private istring assertArgsHandled ( size_t n_args, ArgsAndHandlers ... ) ( )
{
    mstring duplicate, unhandled;

    foreach (i, Arg; ArgsAndHandlers[0 .. n_args])
    {
        foreach (Arg2; ArgsAndHandlers[0 .. i])
        {
            static if (is(Arg == Arg2))
            {
                duplicate ~= (" " ~ Arg.stringof);
                break;
            }
        }

        // Use an unnecessary control variable to work around DMD bug 14835.
        bool good = false;
        foreach (Handler; ArgsAndHandlers[n_args .. $])
        {
            static if (is(Handler : void delegate(Arg)))
            {
                good = true;
                break;
            }
        }

        if (!good) unhandled ~= (" " ~ Arg.stringof);
    }

    mstring result;

    if (duplicate.length)
    {
        result ~= "Duplicate argument types:";
        result ~= duplicate;
    }

    if (unhandled.length)
    {
        if (duplicate.length)
            result ~= ", ";

        result ~= "Unhandled argument types:";
        result ~= unhandled;
    }

    return result.length? "static assert(false,\"" ~ result ~ "\");" : null;
}

version ( unittest )
{
    import ocean.core.Test;

    struct A
    {
        uint a;
    }

    struct B
    {
        uint b;
    }

    struct ToErase
    {
        uint c;
    }

    struct Args
    {
        uint a;
        uint b;
        uint c;
    }

    void setupArgs ( Options ... ) ( ref Args args, Options options )
    {
        scope dg1 = ( A a )
        {
            args.a = a.a;
        };

        scope dg2 = ( B b )
        {
            args.b = b.b;
        };

        setupOptionalArgs!(options.length)(options, dg1, dg2);
    }

    // for testing eraseFromArgs
    void setupArgsWithErase ( Options ... ) ( ref Args args, Options options )
    {
        scope dg1 = ( A a )
        {
            args.a = 1;
        };

        scope dg2 = ( B b )
        {
            args.b = 2;
        };

        scope dg3 = (ToErase c)
        {
            args.c = c.c;
        };

        setupOptionalArgs!(options.length)(options, dg1, dg2, dg3);

        // forward to setupArgs
        setupArgs(args, eraseFromArgs!(ToErase, options));
    }
}

unittest
{
    // No optional arguments
    {
        Args args;
        setupArgs(args);
        test!("==")(args.a, args.a.init);
        test!("==")(args.b, args.b.init);
    }

    // Valid optional arguments
    {
        Args args;
        setupArgs(args, A(23), B(42));
        test!("==")(args.a, 23);
        test!("==")(args.b, 42);
    }

    // Valid and filtered optional arguments
    {
        Args args;
        setupArgsWithErase(args, A(23), B(42), ToErase(54));
        test!("==")(args.a, 23);
        test!("==")(args.b, 42);
        test!("==")(args.c, 54);
    }

    // Invalid optional arguments
    static assert(!is(typeof({
        struct C { }
        Args args;
        setupArgs(args, C()); // should be a compile-time error
    })));
}
