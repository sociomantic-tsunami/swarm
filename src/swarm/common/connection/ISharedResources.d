/*******************************************************************************

    Helper class to manage the acquiring and relinquishing of a set of resource
    pools of various types which are shared between currently handled requests.

    The template creates a class containing a set of free lists, one per type of
    shared resource. The shared resource types, as well as the names of the
    free list members, are determined by the fields of a struct.

    For example, the following struct:

    ---

        struct Resources
        {
            char[] buffer;
            FiberSelectEvent event;
        }

    ---

    would produce a class with the following members:

    ---

        public FreeList!(buffer) buffer_freelist;
        public FreeList!(event) event_freelist;

    ---

    copyright:      Copyright (c) 2012-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.common.connection.ISharedResources;

import ocean.transition;

/*******************************************************************************

    Template to mixin a class named SharedResources, based on a struct T whose
    fields define the set of possible shared resources which can be acquired by
    a request. SharedResources has the following features:

        * A set of free lists, one for each resource type. The free lists have
          the same names as the fields of the base struct, appened with
          "_freelist".

    Template params:
        T = struct whose fields define the set of shared resources

*******************************************************************************/

template SharedResources_T ( T )
{
    static assert(is(T == struct), "T must be a struct");

    static if ( typeof(T.tupleof).length > 0 )
    {
        /***********************************************************************

            Imports required by template.

        ***********************************************************************/

        import ocean.transition;
        import ocean.core.Traits : FieldType, FieldName;
        import ocean.util.container.pool.FreeList;


        /***********************************************************************

            Recursive template to mix in a series of declarations of free lists,
            one per field of T.

            Template params:
                T = struct whose fields define the types of the free lists to be
                    mixed in
                i = index of struct field being mixed in (recursion counter)

        ***********************************************************************/

        template DeclareFreeList ( T, size_t i )
        {
            const istring DeclareFreeList = "public FreeList!("
                ~ FieldType!(T, i).stringof ~ ") " ~ FieldName!(i, T) ~ "_freelist;";
        }

        template DeclareFreeLists ( T, size_t i = 0 )
        {
            static if ( i == T.tupleof.length - 1 )
            {
                const istring DeclareFreeLists = DeclareFreeList!(T, i);
            }
            else
            {
                const istring DeclareFreeLists = DeclareFreeList!(T, i) ~
                    DeclareFreeLists!(T, i + 1);
            }
        }

//      pragma(msg, DeclareFreeLists!(T));


        /***********************************************************************

            Recursive template to mix in a series of news of free lists, one per
            field of T.

            Template params:
                T = struct whose fields define the types of the free lists to be
                    mixed in
                i = index of struct field being mixed in (recursion counter)

        ***********************************************************************/

        template NewFreeList ( T, size_t i )
        {
            const istring NewFreeList = "this." ~ FieldName!(i, T) ~ "_freelist"
                " = new FreeList!(" ~ FieldType!(T, i).stringof ~ ");";
        }

        template NewFreeLists ( T, size_t i = 0 )
        {
            static if ( i == T.tupleof.length - 1 )
            {
                const istring NewFreeLists = NewFreeList!(T, i);
            }
            else
            {
                const istring NewFreeLists = NewFreeList!(T, i) ~
                    NewFreeLists!(T, i + 1);
            }
        }

//      pragma(msg, NewFreeLists!(T));


        /***********************************************************************

            Class containing a set of free lists.

        ***********************************************************************/

        class SharedResources
        {
            /*******************************************************************

                Local re-definition of T.

            *******************************************************************/

            public alias T Resources;


            /*******************************************************************

                Mix in the free lists based on the fields of T.

            *******************************************************************/

            mixin(DeclareFreeLists!(T));


            /*******************************************************************

                Constructor. Initialises the free lists.

            *******************************************************************/

            public this ( )
            {
                mixin(NewFreeLists!(T));
            }
        }
    }
    else
    {
        static assert(false, "struct T must have one or more fields");
    }
}

version (UnitTest)
{
    import ocean.core.Test;

    struct Resources
    {
        int[] a;
        mstring b;
    }

    // Wrapped inside a struct to allow importing this module
    // at module level and mixing `SharedResources_T` in the
    // same module.
    struct UnitTestClashFix
    {
        mixin SharedResources_T!(Resources);
    }
}

unittest
{
    auto resources = new UnitTestClashFix.SharedResources;
    auto item = resources.a_freelist.get(new int[10]);
    test!("==")(item.length, 10);
}
