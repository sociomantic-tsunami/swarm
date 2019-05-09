/*******************************************************************************

    Interface and base scope class containing getter methods to acquire
    resources needed by a request. Multiple calls to the same getter only result
    in the acquiring of a single resource of that type, so that the same
    resource is used over the life time of a request. When a request resource
    instance goes out of scope all required resources are automatically
    relinquished.

    Note that any imports required by the struct defining the set of resources
    must also be imported in the module where the IRequestResources_T template
    is mixed in.

    copyright:      Copyright (c) 2012-2017 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.common.request.model.IRequestResources;



/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.meta.codegen.Identifier : identifier;
import ocean.meta.traits.Basic : ArrayKind, isArrayType;
import ocean.transition;


/*******************************************************************************

    Template to determine the return type of a getter method (see below).
    Getters for dynamic arrays return a pointer to the array, getters for other
    types return the instance itself.

    Template params:
        T = struct whose fields define the types of the getters to be mixed in
        i = index of struct field

*******************************************************************************/

public template GetterReturnType ( T, size_t i )
{
    static if ( isArrayType!(typeof(T.tupleof[i])) == ArrayKind.Dynamic )
    {
        alias typeof(T.tupleof[i])* GetterReturnType;
    }
    else
    {
        alias typeof(T.tupleof[i]) GetterReturnType;
    }
}


/*******************************************************************************

    Templates to mixin an interface named IRequestResources, based on a class
    Shared (which is assumed to have been created by the SharedResources_T mixin
    template, above). The fields of the struct from which Shared was constructed
    define the set of possible shared resources which can be acquired by a
    request. IRequestResources has the following features:

        * A getter method per field of the base struct of Shared. The getters
          have the same names as the fields of the base struct.

    Template params:
        Shared = class created by the SharedResources_T template, based on a
            struct whose fields define the set of shared resources which can be
            acquired by a request

*******************************************************************************/

public template IRequestResources_T ( Shared )
{
    static assert(is(Shared == class), "Shared must be a class");


    /***************************************************************************

        Imports required by template.

    ***************************************************************************/

    import ocean.meta.codegen.Identifier : identifier;
    import ocean.transition;


    /***************************************************************************

        Recursive template to mix in a series of declarations of getter methods,
        one per field of the struct upon which Shared is based.

        Template params:
            T = struct whose fields define the types of the getters to be mixed
                in
            i = index of struct field being mixed in (recursion counter)

    ***************************************************************************/

    template Getter ( T, size_t i )
    {
        static immutable istring Getter = GetterReturnType!(T, i).stringof ~ " " ~
            identifier!(T.tupleof[i]) ~ "();";
    }

    template Getters ( T, size_t i = 0 )
    {
        static if ( i == T.tupleof.length - 1 )
        {
            static immutable istring Getters = Getter!(T, i);
        }
        else
        {
            static immutable istring Getters =
                Getter!(T, i) ~ Getters!(T, i + 1);
        }
    }

//    pragma(msg, Getters!(Shared.Resources));


    /***************************************************************************

        Interface to a request resource acquirer / relinquisher.

    ***************************************************************************/

    interface IRequestResources
    {
        mixin(Getters!(Shared.Resources));
    }
}



/*******************************************************************************

    Templates to mixin a scope class named RequestResources, based on a class
    Shared (which is assumed to have been created by the SharedResources_T mixin
    template, in swarm.node.connection.ISharedResources), and implementing
    the IRequestResources interface (defined by the IRequestResources_T
    template, above). The fields of the struct from which Shared was constructed
    define the set of possible shared resources which can be acquired by a
    request. IRequestResources has the following features:

        * A constructor which accepts a reference to an instance of Shared. This
          instance is used to acquire and relinquish resources required by a
          request.
        * A getter method per field of the base struct of Shared. The getters
          have the same names as the fields of the base struct.
        * The initial call to one of the getters acquires a resource from the
          Shared instance passed to the constructor. Subsequent calls to the
          same getter return the previously acquired resource.
        * All acquired resources are relinquished by the destructor (hence the
          class is designed as a scope class).

    Note that this setup carries the implied assumption that each request can
    only acquire one instance of each type of shared resource.

    Template params:
        Shared = class created by the SharedResources_T template, based on a
            struct whose fields define the set of shared resources which can be
            acquired by a request

*******************************************************************************/

public template RequestResources_T ( Shared )
{
    static assert(is(Shared == class), "Shared must be a class");


    /***************************************************************************

        Imports required by template.

    ***************************************************************************/

    import ocean.meta.codegen.Identifier : identifier;
    import ocean.meta.traits.Basic : isArrayType;
    import ocean.transition;


    /***************************************************************************

        Template to determine the return value of a getter method (see below).
        Getters for dynamic arrays return a pointer to the array, getters for
        other types return the instance itself.

        Template params:
            T = struct whose fields define the types of the getters to be mixed
                in
            i = index of struct field

    ***************************************************************************/

    template GetterReturnValue ( T, size_t i )
    {
        static if ( isArrayType!(typeof(T.tupleof[i])) == ArrayKind.Dynamic )
        {
            static immutable istring GetterReturnValue =
                "&this.acquired." ~ identifier!(T.tupleof[i]) ~ ";";
        }
        else
        {
            static immutable istring GetterReturnValue =
                "this.acquired." ~ identifier!(T.tupleof[i]) ~ ";";
        }
    }


    /***************************************************************************

        Recursive template to mix in a series of getter methods, one per field
        of T. The getter methods get an instance from the appropriate free list
        in shared resources (or a new instance if the free list is empty). The
        instance is passed to the appropriate init method (see below) before
        being returned.

        Template params:
            T = struct whose fields define the types of the getters to be mixed
                in
            i = index of struct field being mixed in (recursion counter)

        TODO: could this be done as a template mixin, not a string mixin?

    ***************************************************************************/

    template Getter ( T, size_t i )
    {
        static immutable istring Getter =
            GetterReturnType!(T, i).stringof ~ " " ~ identifier!(T.tupleof[i]) ~ "()" ~
            "{" ~
                "if(!this.acquired." ~ identifier!(T.tupleof[i]) ~ ")" ~
                "{" ~
                    "this.acquired." ~ identifier!(T.tupleof[i]) ~ "=" ~
                    "this.shared_resources." ~ identifier!(T.tupleof[i]) ~ "_freelist" ~
                    ".get(this.new_" ~ identifier!(T.tupleof[i]) ~ ");" ~
                    "this.init_" ~ identifier!(T.tupleof[i]) ~
                        "(this.acquired." ~ identifier!(T.tupleof[i]) ~ ");" ~
                "}" ~
                "return " ~ GetterReturnValue!(T, i) ~
            "}";
    }

    template Getters ( T, size_t i = 0 )
    {
        static if ( i == T.tupleof.length - 1 )
        {
            static immutable istring Getters = Getter!(T, i);
        }
        else
        {
            static immutable istring Getters = Getter!(T, i) ~ Getters!(T, i + 1);
        }
    }

//    pragma(msg, Getters!(Shared.Resources));


    /***************************************************************************

        Recursive template to mix in a series of methods to create new resource
        instances, one per field of T. The mixed in methods are abstract. They
        are required by the get() methods of the FreeLists in the shared
        resources class.

        Template params:
            T = struct whose fields define the types of the methods to be mixed
                in
            i = index of struct field being mixed in (recursion counter)

    ***************************************************************************/

    template Newer ( T, size_t i )
    {
        static immutable istring Newer = "protected abstract " ~ typeof(T.tupleof[i]).stringof ~ " " ~
            "new_" ~ identifier!(T.tupleof[i]) ~ "();";
    }

    template Newers ( T, size_t i = 0 )
    {
        static if ( i == T.tupleof.length - 1 )
        {
            static immutable istring Newers = Newer!(T, i);
        }
        else
        {
            static immutable istring Newers = Newer!(T, i) ~ Newers!(T, i + 1);
        }
    }

//    pragma(msg, Newers!(Shared.Resources));


    /***************************************************************************

        Recursive template to mix in a series of methods to initialise resource
        instances, one per field of T. The default behaviour of the mixed in
        methods depends on the type of the field:
            * If the field is a dynamic array type, then its length is reset to
              0.
            * Otherwise, the method does nothing by default.

        Either way, the mixed in methods may be overridden by derived classes to
        implement any special initialisation behaviour required.

        Template params:
            T = struct whose fields define the types of the methods to be mixed
                in
            i = index of struct field being mixed in (recursion counter)

    ***************************************************************************/

    template Initialiser ( T, size_t i )
    {
        static if ( isArrayType!(typeof(T.tupleof[i])) == ArrayKind.Dynamic )
        {
            static immutable istring Initialiser =
                "protected void " ~
                "init_" ~ identifier!(T.tupleof[i]) ~ "(ref " ~ typeof(T.tupleof[i]).stringof ~ " f)" ~
                "{f.length=0; enableStomping(f);}";
        }
        else
        {
            static immutable istring Initialiser =
                "protected void " ~
                "init_" ~ identifier!(T.tupleof[i]) ~ "(" ~ typeof(T.tupleof[i]).stringof ~ "){}";
        }
    }

    template Initialisers ( T, size_t i = 0 )
    {
        static if ( i == T.tupleof.length - 1 )
        {
            static immutable istring Initialisers = Initialiser!(T, i);
        }
        else
        {
            static immutable istring Initialisers =
                Initialiser!(T, i) ~ Initialisers!(T, i + 1);
        }
    }

//    pragma(msg, Initialisers!(Shared.Resources));


    /***************************************************************************

        Recursive template to mix in a series of methods to relinquish acquired
        resources.

        Template params:
            T = struct whose fields define the types of the methods to be mixed
                in
            i = index of struct field being mixed in (recursion counter)

    ***************************************************************************/

    template Recycler ( T, size_t i )
    {
        static immutable istring Recycler =
            "if(this.acquired." ~ identifier!(T.tupleof[i]) ~ ")" ~
            "{" ~
                "this.shared_resources." ~ identifier!(T.tupleof[i]) ~ "_freelist" ~
                ".recycle(this.acquired." ~ identifier!(T.tupleof[i]) ~ ");" ~
            "}";
    }

    template Recyclers ( T, size_t i = 0 )
    {
        static if ( i == T.tupleof.length - 1 )
        {
            static immutable istring Recyclers = Recycler!(T, i);
        }
        else
        {
            static immutable istring Recyclers = Recycler!(T, i) ~ Recyclers!(T, i + 1);
        }
    }

//    pragma(msg, Recyclers!(Shared.Resources));


    /***************************************************************************

        Interface to a request resource acquirer / relinquisher.

    ***************************************************************************/

    abstract scope class RequestResources : IRequestResources
    {
        /***********************************************************************

            Shared resources instance, plus invariant which checks that it is
            always non-null.

        ***********************************************************************/

        private Shared shared_resources;

        invariant ()
        {
            assert(this.shared_resources !is null,
                "shared resources instance is null");
        }


        /***********************************************************************

            Set of currently acquired resources.

        ***********************************************************************/

        protected Shared.Resources acquired;


        /***********************************************************************

            Constructor.

            Params:
                shared_resources = shared resources instance to use for
                    acquiring and relinquishing resources

        ***********************************************************************/

        public this ( Shared shared_resources )
        {
            this.shared_resources = shared_resources;
        }


        /***********************************************************************

            Destuctor. Relinquishes any acquired resources.

        ***********************************************************************/

        ~this ( )
        {
            mixin(Recyclers!(Shared.Resources));
        }


        /***********************************************************************

            Mix in the resource getter methods.

        ***********************************************************************/

        mixin(Getters!(Shared.Resources));


        /***********************************************************************

            Mixin the abstract resources newer methods.

        ***********************************************************************/

        mixin(Newers!(Shared.Resources));


        /***********************************************************************

            Mixin the abstract resources initialiser methods.

        ***********************************************************************/

        mixin(Initialisers!(Shared.Resources));
    }
}
version (UnitTest)
{
    import ocean.core.Test;

    // to avoid clashing of mixed in names from different module tests
    struct LocalNamespace
    {
        // ISharedResources module has a version (UnitTest) mixin
        // that provides SharedResources symbol
        public import swarm.common.connection.ISharedResources
            : UnitTestClashFix;

        mixin IRequestResources_T!(UnitTestClashFix.SharedResources);
        mixin RequestResources_T!(UnitTestClashFix.SharedResources);
    }
}

unittest
{
    scope class Resources : LocalNamespace.RequestResources
    {
        this ()
        {
            super(new LocalNamespace.UnitTestClashFix.SharedResources);
        }

        override int[] new_a() { return new int[100]; }
        override mstring new_b() { return new char[42]; }
    }

    scope resources = new Resources;
    auto value = resources.a();
    test!("==")(value.length, 0);
    auto initial_ptr = value.ptr;
    value.length = 100;
    test!("is")(value.ptr, initial_ptr);
    value.length = 200;
    test!("!is")(value.ptr, initial_ptr);
}
