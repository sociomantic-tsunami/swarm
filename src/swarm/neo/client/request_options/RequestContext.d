/*******************************************************************************

    Struct wrapping the user-specified context for a request.

    Used for two purposes:
        1. As an option struct to be passed to request assignment methods in the
           client.
        2. As a workaround for the fact that ocean's contiguous serializer
           rejects unions. It is thus not possible to store a normal context
           union (e.g. ocean.core.ContextUnion) in a request's user-specified
           arguments.

    Note: in D2, `alias this` would greatly simplify this wrapper struct.

    copyright: Copyright (c) 2016-2017 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.neo.client.request_options.RequestContext;

/// ditto
public struct RequestContext
{
    import ocean.transition;
    import ocean.core.ContextUnion;

    private mixin TypeofThis!();

    /***************************************************************************

        The context union, stored as a fixed-size array of ubytes. Methods which
        need to access the context cast it to a ContextUnion (see context()).

    ***************************************************************************/

    private ubyte[ContextUnion.sizeof] context_;

    /***************************************************************************

        "Constructor" which creates an instance with the context set as an
        integer.

        Params:
            i = integer to set as context

        Returns:
            instance of this struct with context set as requested

    ***************************************************************************/

    public static This opCall ( ulong i )
    {
        This instance;
        instance.integer = i;
        return instance;
    }

    /***************************************************************************

        "Constructor" which creates an instance with the context set as an
        object.

        Params:
            o = object to set as context

        Returns:
            instance of this struct with context set as requested

    ***************************************************************************/

    public static This opCall ( Object o )
    {
        This instance;
        instance.object = o;
        return instance;
    }

    /***************************************************************************

        "Constructor" which creates an instance with the context set as a
        pointer.

        Params:
            p = pointer to set as context

        Returns:
            instance of this struct with context set as requested

    ***************************************************************************/

    public static This opCall ( void* p )
    {
        This instance;
        instance.pointer = p;
        return instance;
    }

    /***************************************************************************

        Sets the context to an integer.

        Params:
            i = integer to set as context

    ***************************************************************************/

    public void integer ( ulong i )
    {
        (&this).context().integer = i;
    }

    /***************************************************************************

        Sets the context to an object.

        Params:
            o = object to set as context

    ***************************************************************************/

    public void object ( Object o )
    {
        (&this).context().object = o;
    }

    /***************************************************************************

        Sets the context to a pointer.

        Params:
            p = pointer to set as context

    ***************************************************************************/

    public void pointer ( void* p )
    {
        (&this).context().pointer = p;
    }

    /***************************************************************************

        Returns:
            integer context

        Throws:
            if the context has not been set to an integer

    ***************************************************************************/

    public ulong integer ( ) const
    {
        return (&this).context().integer;
    }

    /***************************************************************************

        Returns:
            object context

        Throws:
            if the context has not been set to an object

    ***************************************************************************/

    public Object object ( ) const
    {
        return (&this).context().object;
    }

    /***************************************************************************

        Returns:
            pointer context

        Throws:
            if the context has not been set to a pointer

    ***************************************************************************/

    public void* pointer ( ) const
    {
        return (&this).context().pointer;
    }

    /***************************************************************************

        Returns:
            SmartUnion active enum denoting which type has been set

    ***************************************************************************/

    public ContextUnion.Active active ( ) const
    {
        return (&this).context().active;
    }

    /***************************************************************************

        Returns:
            this.context_, usable as a ContextUnion

    ***************************************************************************/

    private ContextUnion* context ( ) const
    {
        return cast(ContextUnion*)(&this).context_.ptr;
    }
}
