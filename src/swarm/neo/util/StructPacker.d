/*******************************************************************************

    Functions to pack a struct instance and all contained array buffers into a
    contiguous chunk of memory.

    The packer is distinct from a serializer (e.g. ocean's contiguous
    serializer) in that it stores memory addresses in the packed data. Thus,
    packed data can explicitly *not* be exported to disk or sent over the
    network.

    Packing (as opposed to serializing) is useful in scenarios where you need to
    store data of an undefined type in a reusable buffer. For example, swarm
    client requests use the packer to store the data required for their context
    in a reusable buffer in an abstract aggregate that knows nothing about the
    different types of requests.

    Internally, the packer is similar to ocean's contiguous serializer, but:
        * Can handle non-array reference types (e.g. delegates, pointers).
        * Can handle unions.
        * Automatically sets the pointers of packed arrays to point to the
          array data contained in the packed buffer.

    Note: this code is generic (i.e. does not rely on anything else in swarm),
    but is not placed in ocean as there are no other current use cases for it,
    outside of the request core of swarm neo.

    Copyright:
        Copyright (c) 2017 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.neo.util.StructPacker;

import ocean.transition;
import ocean.core.Traits;
import ocean.core.Verify;

/*******************************************************************************

    Packs `s` into the provided buffer, ensuring that the content of all
    dynamic array fields are contained fully within the buffer.

    Note that the data in the buffer after packing should not be copied and then
    unpacked -- any array slices will not be updated by copying the packed
    buffer and will hence point to the wrong memory. (If you need to copy a
    packed buffer, unpack it first and then pack it into a new buffer.)

    Params:
        S = type to pack
        s = thing to pack
        buf = buffer to pack into

*******************************************************************************/

public void pack ( S ) ( S s, ref void[] buf )
{
    checkPackable!(S)();

    // Do a simple, binary copy of the struct.
    buf.length = S.sizeof;
    enableStomping(buf);
    buf[] = (cast(void*)&s)[0..S.sizeof];

    // Handle any dynamic array fields. (Note that it's safe to cast away const
    // at this point as we're referring to the copy of s inside buf, no longer
    // to s itself.)
    auto packed_struct = cast(Unqual!(S)*)buf.ptr;
    packStructDynamicArrays(*packed_struct, buf);
}

/*******************************************************************************

    Interprets the data in the provided buffer (which must have been created by
    a call to `pack`, above) as a struct of the specific type.

    Params:
        S = type to unpack
        packed = buffer containing the packed thing. (Note that the buffer is
            passed as mutable as it's cast to S*, which may be mutable. The
            buffer itself is not modified inside this function, though.)

    Returns:
        pointer to the buffer interpreted as a pointer to an instance of the
        packed type

*******************************************************************************/

public S* unpack ( S ) ( void[] packed )
{
    verify(packed.length >= S.sizeof);

    return cast(S*)packed.ptr;
}

/*******************************************************************************

    Packs dynamic arrays inside a struct into the provided buffer. Both
    dynamic array fields directly contained in the struct and dynamic array
    fields of nested structs are handled. The contents of any dynamic arrays
    found will be packed into `buf` and their slices updated to point to the
    content just added to the packing buffer.

    Params:
        S = type of struct to pack dynamic arrays from
        s = struct instance to pack dynamic arrays from
        buf = buffer to pack into

*******************************************************************************/

private void packStructDynamicArrays ( S ) ( ref S s, ref void[] buf )
{
    foreach ( ref f; s.tupleof )
    {
        // Pack dynamic array fields of S.
        static if ( isDynamicArrayType!(typeof(f)) )
            packDynamicArray(f, buf);
        // Recursively pack dynamic arrays in struct fields of S.
        else static if ( ContainsDynamicArray!(typeof(f)) )
            packStructDynamicArrays(f, buf);
    }
}

/*******************************************************************************

    Packs an array into the provided buffer. This has three steps:
        1. The array's content is appended to the packing buffer.
        2. The array slice is updated to point to the content just added to the
           packing buffer.
        3. If the array's elements are, in turn, dynamic arrays, repeats the
           process (recursively) for each element.

    Params:
        A = type of array to pack
        array = slice to pack and update to point to the packed content
        buf = buffer to pack into

*******************************************************************************/

private void packDynamicArray ( A ) ( ref A[] array, ref void[] buf )
{
    static assert(isPrimitiveType!(BaseTypeOfArrays!(A)));

    // Append the array content to the buffer.
    auto start = buf.length;
    buf ~= array;

    // Adjust the array slice to refer to the packed content in the
    // buffer.
    array = cast(A[])buf[start..$];

    // Recursively pack arrays of arrays.
    static if (isDynamicArrayType!(A))
    {
        foreach ( ref e; array )
            packDynamicArray(e, buf);
    }
    else
        static assert(!hasIndirections!(A));
}

version ( UnitTest )
{
    import ocean.core.Test;
    import ocean.core.DeepCompare : deepEquals;

    // Test helper function to pack, unpack, and compare against the
    // original.
    bool packUnpack ( S ) ( S s )
    {
        void[] buf;
        pack(S.init, buf);
        auto unpacked = unpack!(S)(buf);
        return deepEquals(s, *unpacked);
    }
}

// Tests for `pack` and `unpack`.
unittest
{
    struct Simple
    {
        int i = 23;
        float f = 23.23;
    }
    test(packUnpack(Simple.init));

    struct Array
    {
        int i = 23;
        mstring str = "hello".dup;
    }
    test(packUnpack(Array.init));

    struct Pointer
    {
        void* p;
    }
    test(packUnpack(Pointer.init));

    struct StaticArray
    {
        ubyte[10] a = [0,1,2,3,4,5,6,7,8,9];
    }
    test(packUnpack(StaticArray.init));

    struct StaticArrayNested
    {
        struct S
        {
            int i;
        }

        S[10] a = [S(0),S(1),S(2),S(3),S(4),S(5),S(6),S(7),S(8),S(9)];
    }
    test(packUnpack(StaticArrayNested.init));

    struct Array2d
    {
        int i = 23;
        mstring[] str = ["hello".dup, "how".dup, "amazing".dup];
    }
    test(packUnpack(Array2d.init));

    struct Delegate
    {
        void delegate ( ) d;
    }
    test(packUnpack(Delegate.init));

    struct Union
    {
        union U
        {
            void* p;
            int i;
        }

        U u;
    }
    test(packUnpack(Union.init));

    struct Nested
    {
        int i = 23;
        float f = 23.23;

        struct S
        {
            int i = 47;
        }

        S s;
    }
    test(packUnpack(Nested.init));

    struct NestedPointer
    {
        struct S
        {
            void* p;
        }

        S s;
    }
    test(packUnpack(NestedPointer.init));

    // Replicates the real situation that we have in RequestCore.
    struct Context
    {
        struct UserSpecifiedParams
        {
            struct Args
            {
                mstring channel = "campaign_metadata".dup;
                hash_t key = 23;
            }

            Args a;
            void delegate ( ) notifier;
        }

        UserSpecifiedParams usp;

        struct SharedWorking
        {
            void* p;
        }

        SharedWorking shared_working;
    }
    test(packUnpack(Context.init));
}

/*******************************************************************************

    Statically asserts that the specified type can be packed by the `pack`
    function, above.

    Params:
        S = type to check

*******************************************************************************/

private void checkPackable ( S ) ( )
{
    foreach ( i, F; typeof(S.tupleof) )
    {
        // Arrays are allowed, if...
        static if ( isDynamicArrayType!(F) )
        {
            // ...they only contain primitive types. (This prevents pointers
            // from becoming misaligned when the array contents are copied to
            // the end of the packing buffer.)
            static assert(isPrimitiveType!(BaseTypeOfArrays!(F)));
        }

        // Static arrays are allowed, if...
        static if ( isStaticArrayType!(F) )
        {
            // ...they don't contain dynamic arrays.
            static assert(!ContainsDynamicArray!(F));
        }

        // Structs are allowed, if...
        static if ( is (F == struct) )
        {
            // ...they could be packed on their own.
            checkPackable!(F);
        }

        // Unions are allowed, if...
        static if ( is (F == union) )
        {
            // ...they don't contain dynamic arrays.
            static assert(!ContainsDynamicArray!(F));
        }
    }
}

// Tests for `checkPackable` with disallowed types. (Allowed types are tested in
// the unittest for `pack`, above.)
unittest
{
    // Struct with a non-primitive array disallowed.
    struct ArrayNonPrim
    {
        void*[] a;
    }
    static assert(!is(typeof({
        checkPackable!(ArrayNonPrim)();
    })));

    // Struct with a nested struct containing a non-primitive array disallowed.
    struct Nested
    {
        struct S
        {
             void*[] a;
        }

        S s;
    }
    static assert(!is(typeof({
        checkPackable!(Nested)();
    })));

    // Struct with a static array of dynamic arrays disallowed.
    struct StaticArrayDynamic
    {
        struct S
        {
            mstring str;
        }

        S[12] a;
    }
    static assert(!is(typeof({
        checkPackable!(StaticArrayDynamic)();
    })));

    // Struct with a union with a dynamic array field disallowed.
    struct UnionDynamic
    {
        union U
        {
            void[] a;
        }

        U u;
    }
    static assert(!is(typeof({
        checkPackable!(UnionDynamic)();
    })));
}
