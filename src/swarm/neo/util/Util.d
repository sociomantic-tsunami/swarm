/*******************************************************************************

    Small utility functions required by neo.

    Copyright: Copyright (c) 2016-2017 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.neo.util.Util;

/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.meta.types.Qualifiers;

/*******************************************************************************

    Appends slices referencing the `x` values to `slices`. For dynamic arrays
    a slice to the length is appended, then the array slice itself.

    Params:
        slices = the destination array to append slices to all `x` values
        x      = the values of which to append slice references to `slices`

*******************************************************************************/

deprecated("This function is not safe to use - Use `Payload` facilities instead")
void appendSlices ( Types ... ) ( ref void[][] slices, ref Types x )
{
    foreach (i, T; Types)
    {
        static if (is(T Element: Element[]))
        {
            /*
             * x[i] is a dynamic array. To slice the data of x.length, we use
             * the implementation detail that a dynamic array is in fact a
             * struct:
             *
             * struct Array
             * {
             *     size_t length;
             *     Element* ptr;
             * }
             *
             * x[i] is of type array, and Array.length.offsetof = 0 so
             *
             *     &x[i]
             *
             * is equivalent to
             *
             *     &(x[i].length)
             *
             * Using this we create a slice to the data of x[i].length with
             *
             *     (cast(void*)(&x[i]))[0 .. size_t.sizeof]
             *
             * A unittest at the end of the module verifies that this method
             * works. Yes, this is a hack to avoid storing the array length in
             * a separate variable in order to slice it, which would vastly
             * increase the complexity of this function.
             */
            static if (is(T == Element[]))
            {
                slices ~= (cast(void*)(&x[i]))[0 .. size_t.sizeof];
            }
            // Append a slice to the array content.
            slices ~= x[i];
        }
        else
        {
            slices ~= (cast(void*)(&x[i]))[0 .. x[i].sizeof];
        }
    }
}

char[] TupleToSlices ( Types ... ) ( string name )
{
    char[] code;

    foreach (i, T; Types)
    {
        auto var = name ~ "[" ~ i.stringof ~ "]";

        static if (i)
            code ~= ",";

        static if (is(T Element: Element[]))
        {
            /*
             * If the i-th variable is a dynamic array, slice its length using
             * the method described in appendSlices().
             */
            static if (is(T == Element[]))
                code ~= "(cast(void*)(&" ~ var ~ "))[0.." ~ size_t.sizeof.stringof ~ "],";

            code ~= var;
        }
        else
        {
            code ~= "(cast(void*)(&" ~ var ~ "))[0.." ~ T.sizeof.stringof ~ "]";
        }
    }

    return code;
}

version ( unittest )
{
    import ocean.core.Test;
    import ocean.core.Tuple;
}

unittest
{
    Tuple!(char[]) items;
    items[0] = "Hello World!".dup;

    void f ( void[][] slices ... )
    {
        test!("==")(slices.length, 2);
        test!("==")(slices[0].length, items[0].length.sizeof);
        test!("==")(*cast(size_t*)slices[0].ptr, items[0].length);
        test!("is")(slices[1], items[0]);
    }

    mixin("f(" ~ TupleToSlices!(typeof(items))("items") ~ ");");
}
