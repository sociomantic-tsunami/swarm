/*******************************************************************************

    Helper structs to acquire and relinquish shared resources during the
    handling of a request.

    Copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.neo.util.AcquiredResources;

import ocean.transition;

private struct WrappedArray ( T )
{
    static assert(!is(T == void));

    private void[]* buffer;

    invariant ( )
    {
        assert(this.buffer.length % T.sizeof == 0);
    }

    public size_t length ( )
    {
        return this.buffer.length / T.sizeof;
    }

    public void length ( size_t len )
    {
        this.buffer.length = len * T.sizeof;
        enableStomping(*this.buffer);
    }

    public void opCatAssign ( T elem )
    {
        this.length = this.length + 1;
        this.opIndexAssign(elem, this.length - 1);
    }

    public T* opIndex ( size_t t_index )
    {
        return this.getElement(t_index);
    }

    public void opIndexAssign ( T elem, size_t t_index )
    {
        *this.getElement(t_index) = elem;
    }

    public T[] opSlice ( )
    {
        return (cast(T*)this.buffer.ptr)[0..this.length];
    }

    public T[] opSlice ( size_t start, size_t end )
    {
        return (cast(T*)this.buffer.ptr)[start..end];
    }

    public int opApply ( int delegate ( ref T ) dg )
    {
        int res;
        for ( size_t i = 0; i < this.length; i++ )
        {
            res = dg(*this.getElement(i));
            if ( res )
                break;
        }
        return res;
    }

    public int opApply ( int delegate ( ref size_t, ref T ) dg )
    {
        int res;
        for ( size_t i = 0; i < this.length; i++ )
        {
            res = dg(i, *this.getElement(i));
            if ( res )
                break;
        }
        return res;
    }

    public int opApplyReverse ( int delegate ( ref T ) dg )
    {
        int res;
        for ( size_t i = this.length - 1; i >= 0; i-- )
        {
            res = dg(*this.getElement(i));
            if ( res )
                break;
        }
        return res;
    }

    public int opApplyReverse ( int delegate ( ref size_t, ref T ) dg )
    {
        int res;
        for ( size_t i = this.length - 1; i >= 0; i-- )
        {
            res = dg(i, *this.getElement(i));
            if ( res )
                break;
        }
        return res;
    }

    private T* getElement ( size_t t_index )
    in
    {
        assert(t_index < this.length);
    }
    body
    {
        return cast(T*)(this.buffer.ptr + (t_index * T.sizeof));
    }
}

/*******************************************************************************

    Set of acquired arrays of the templated type. An external source of untyped
    arrays -- a FreeList!(ubyte[]) -- is required. When arrays are acquired
    (via the acquire() method), they are requested from the free list and stored
    internally in a container array. When the arrays are no longer required, the
    relinquishAll() method will return them to the free list. Note that the
    container array used to store the acquired arrays is also itself acquired
    from the free list and relinquished by relinquishAll().

    Params:
        T = element type of the arrays

*******************************************************************************/

public struct AcquiredArraysOf ( T )
{
    import ocean.util.container.pool.FreeList;

    /***************************************************************************

        Figure out the return type of this.acquire. It's pointless (and not
        possible) to have a WrappedArray!(void), so if T is void, this.acquire
        simply returns a void[]* directly. Otherwise, it returns a
        WrappedArray!(T).

    ***************************************************************************/

    static if (is(T == void) )
    {
        private alias void[]* AcquireReturnType;
    }
    else
    {
        private alias WrappedArray!(T) AcquireReturnType;
    }

    /***************************************************************************

        Externally owned pool of untyped buffers, passed in via initialise().

    ***************************************************************************/

    private FreeList!(ubyte[]) buffer_pool;

    /***************************************************************************

        List of void[] backing buffers for acquired arrays of T. This array is
        stored as a WrappedArray!(void[]) in order to be able to handle it as if
        it's a void[][], where it's actually a simple void[] under the hood.

    ***************************************************************************/

    private WrappedArray!(void[]) acquired;

    /***************************************************************************

        Backing buffer for this.acquired.

    ***************************************************************************/

    private void[] buffer;

    /***************************************************************************

        Initialises this instance. (No other methods may be called before
        calling this method.)

        Params:
            buffer_pool = shared pool of untyped arrays

    ***************************************************************************/

    public void initialise ( FreeList!(ubyte[]) buffer_pool )
    {
        this.buffer_pool = buffer_pool;
    }

    /***************************************************************************

        Gets a pointer to a new array, acquired from the shared resources pool.

        Important note about array casting: care must be taken when casting an
        array to a type of a different element size. Sizing the array first,
        then casting is fine, e.g.:

        ---
            AcquiredArraysOf!(void) arrays;
            arrays.initialise(buffer_pool); // buffer_pool is assumed to exist
            auto void_array = arrays.acquire();

            struct S { int i; hash_t h; }
            (*void_array).length = 23 * S.sizeof;
            auto s_array = cast(S[])*void_array;
        ---

        But casting the array then sizing it has been observed to cause
        segfaults, e.g.:

        ---
            AcquiredArraysOf!(void) arrays;
            arrays.initialise(buffer_pool); // buffer_pool is assumed to exist
            auto void_array = arrays.acquire();

            struct S { int i; hash_t h; }
            auto s_array = cast(S[]*)void_array;
            s_array.length = 23;
        ---

        The exact reason for the segfaults is not known, but it appears to lead
        to corruption of internal GC data (possibly type metadata associated
        with the array's pointer).

        Returns:
            a new array of T (wrapped, if T is not void)

    ***************************************************************************/

    public AcquireReturnType acquire ( )
    in
    {
        assert(this.buffer_pool !is null);
    }
    body
    {
        void[] newBuffer ( size_t capacity )
        {
            auto buffer = this.buffer_pool.get(cast(ubyte[])new void[capacity]);
            buffer.length = 0;
            enableStomping(buffer);

            return buffer;
        }

        // Acquire container buffer, if not already done.
        if ( this.buffer is null )
        {
            this.buffer = newBuffer((void[]).sizeof * 4);
            this.acquired = WrappedArray!(void[])(&this.buffer);
        }

        // Acquire and re-initialise new buffer to return to the user. Store
        // it in the container buffer.
        this.acquired ~= newBuffer(T.sizeof * 4);

        static if (is(T == void) )
        {
            return this.acquired[this.acquired.length-1];
        }
        else
        {
            return WrappedArray!(T)(this.acquired[this.acquired.length-1]);
        }
    }

    /***************************************************************************

        Relinquishes all shared resources acquired by this instance.

    ***************************************************************************/

    public void relinquishAll ( )
    in
    {
        assert(this.buffer_pool !is null);
    }
    body
    {
        if ( this.buffer !is null )
        {
            // Relinquish acquired buffers.
            foreach ( ref inst; this.acquired )
                this.buffer_pool.recycle(cast(ubyte[])inst);

            // Relinquish container buffer.
            this.buffer_pool.recycle(cast(ubyte[])this.buffer);
        }
    }
}

///
unittest
{
    // Demonstrates how a typical global shared resources container should look.
    // A single instance of this would be owned at the top level of the client/
    // node.
    class SharedResources
    {
        import ocean.util.container.pool.FreeList;

        // The pool of untyped buffers required by AcquiredArraysOf.
        private FreeList!(ubyte[]) buffers;

        this ( )
        {
            this.buffers = new FreeList!(ubyte[]);
        }

        // Objects of this class will be newed at scope and passed to request
        // handlers. This allows the handler to acquire various shared resources
        // and have them automatically relinquished when the handler exits.
        class RequestResources
        {
            // Tracker of buffers acquired by the request.
            private AcquiredArraysOf!(void) acquired_void_buffers;

            // Initialise the tracker in the ctor.
            this ( )
            {
                this.acquired_void_buffers.initialise(this.outer.buffers);
            }

            // ...and be sure to relinquish all the acquired resources in the
            // dtor.
            ~this ( )
            {
                this.acquired_void_buffers.relinquishAll();
            }

            // Public method to get a new resource, managed by the tracker.
            public void[]* getVoidBuffer ( )
            {
                return this.acquired_void_buffers.acquire();
            }
        }
    }
}

/*******************************************************************************

    Set of acquired resources of the templated type. An external source of
    elements of this type -- a FreeList!(T) -- as well as a source of untyped
    buffers -- a FreeList!(ubyte[]) -- is required. When resources are acquired
    (via the acquire() method), they are requested from the free list and stored
    internally in an array. When the resources are no longer required, the
    relinquishAll() method will return them to the free list. Note that the
    array used to store the acquired resources is itself acquired from the free
    list of untyped buffers and relinquished by relinquishAll().

    Params:
        T = type of resource

*******************************************************************************/

public struct Acquired ( T )
{
    import ocean.util.container.pool.FreeList;

    /***************************************************************************

        Determine the type of a new resource.

    ***************************************************************************/

    static if ( is(typeof({T* t = new T;})) )
    {
        alias T* Elem;
    }
    else
    {
        alias T Elem;
    }

    /***************************************************************************

        Externally owned pool of untyped buffers, passed in via initialise().

    ***************************************************************************/

    private FreeList!(ubyte[]) buffer_pool;

    /***************************************************************************

        Externally owned pool of T, passed in via initialise().

    ***************************************************************************/

    private FreeList!(T) t_pool;

    /***************************************************************************

        List of acquired resources.

    ***************************************************************************/

    private Elem[] acquired;

    /***************************************************************************

        Initialises this instance. (No other methods may be called before
        calling this method.)

        Params:
            buffer_pool = shared pool of untyped arrays
            t_pool = shared pool of T

    ***************************************************************************/

    public void initialise ( FreeList!(ubyte[]) buffer_pool, FreeList!(T) t_pool )
    {
        this.buffer_pool = buffer_pool;
        this.t_pool = t_pool;
    }

    /***************************************************************************

        Gets a new T.

        Params:
            new_t = lazily initialised new resource

        Returns:
            a new T

    ***************************************************************************/

    public Elem acquire ( lazy Elem new_t )
    in
    {
        assert(this.buffer_pool !is null);
    }
    body
    {
        void[] newBuffer ( size_t capacity )
        {
            auto buffer = this.buffer_pool.get(cast(ubyte[])new void[capacity]);
            buffer.length = 0;
            enableStomping(buffer);

            return buffer;
        }

        // Acquire container buffer, if not already done.
        if ( this.acquired is null )
        {
            this.acquired = cast(Elem[])newBuffer(Elem.sizeof * 4);
        }

        // Acquire new element.
        this.acquired ~= this.t_pool.get(new_t);

        return this.acquired[$-1];
    }

    /***************************************************************************

        Relinquishes all shared resources acquired by this instance.

    ***************************************************************************/

    public void relinquishAll ( )
    in
    {
        assert(this.buffer_pool !is null);
    }
    body
    {
        if ( this.acquired !is null )
        {
            // Relinquish acquired Ts.
            foreach ( ref inst; this.acquired )
                this.t_pool.recycle(inst);

            // Relinquish container buffer.
            this.buffer_pool.recycle(cast(ubyte[])this.acquired);
        }
    }
}

///
unittest
{
    // Type of a specialised resource which may be required by requests.
    struct MyResource
    {
    }

    // Demonstrates how a typical global shared resources container should look.
    // A single instance of this would be owned at the top level of the client/
    // node.
    class SharedResources
    {
        import ocean.util.container.pool.FreeList;

        // The pool of untyped buffers required by Acquired.
        private FreeList!(ubyte[]) buffers;

        // The pool of specialised resources required by Acquired.
        private FreeList!(MyResource) myresources;

        this ( )
        {
            this.buffers = new FreeList!(ubyte[]);
            this.myresources = new FreeList!(MyResource);
        }

        // Objects of this class will be newed at scope and passed to request
        // handlers. This allows the handler to acquire various shared resources
        // and have them automatically relinquished when the handler exits.
        class RequestResources
        {
            private Acquired!(MyResource) acquired_myresources;

            // Initialise the tracker in the ctor.
            this ( )
            {
                this.acquired_myresources.initialise(this.outer.buffers,
                    this.outer.myresources);
            }

            // ...and be sure to relinquish all the acquired resources in the
            // dtor.
            ~this ( )
            {
                this.acquired_myresources.relinquishAll();
            }

            // Public method to get a new resource, managed by the tracker.
            public MyResource* getMyResource ( )
            {
                return this.acquired_myresources.acquire(new MyResource);
            }
        }
    }
}

/*******************************************************************************

    Singleton (per-request) acquired resource of the templated type. An
    external source of elements of this type -- a FreeList!(T) -- is required.
    When the singleton resource is acquired (via the acquire() method), it is
    requested from the free list and stored internally. All subsequent calls to
    acquire() return the same instance. When the resource is no longer required,
    the relinquish() method will return it to the free list.

    Params:
        T = type of resource

*******************************************************************************/

public struct AcquiredSingleton ( T )
{
    import ocean.util.container.pool.FreeList;

    /***************************************************************************

        Determine the type of a new resource.

    ***************************************************************************/

    static if ( is(typeof({T* t = new T;})) )
    {
        alias T* Elem;
    }
    else
    {
        alias T Elem;
    }

    /***************************************************************************

        Externally owned pool of T, passed in via initialise().

    ***************************************************************************/

    private FreeList!(T) t_pool;

    /***************************************************************************

        Acquired resource.

    ***************************************************************************/

    private Elem acquired;

    /***************************************************************************

        Initialises this instance. (No other methods may be called before
        calling this method.)

        Params:
            t_pool = shared pool of T

    ***************************************************************************/

    public void initialise ( FreeList!(T) t_pool )
    {
        this.t_pool = t_pool;
    }

    /***************************************************************************

        Gets the singleton T instance.

        Params:
            new_t = lazily initialised new resource

        Returns:
            singleton T instance

    ***************************************************************************/

    public Elem acquire ( lazy Elem new_t )
    in
    {
        assert(this.t_pool !is null);
    }
    body
    {
        if ( this.acquired is null )
            this.acquired = this.t_pool.get(new_t);

        assert(this.acquired !is null);

        return this.acquired;
    }

    /***************************************************************************

        Gets the singleton T instance.

        Params:
            new_t = lazily initialised new resource
            reset = delegate to call on the singleton instance when it is first
                acquired from the pool. Should perform any logic required to
                reset the instance to its initial state

        Returns:
            singleton T instance

    ***************************************************************************/

    public Elem acquire ( lazy Elem new_t, void delegate ( Elem ) reset )
    in
    {
        assert(this.t_pool !is null);
    }
    body
    {
        if ( this.acquired is null )
        {
            this.acquired = this.t_pool.get(new_t);
            reset(this.acquired);
        }

        assert(this.acquired !is null);

        return this.acquired;
    }

    /***************************************************************************

        Relinquishes singleton shared resources acquired by this instance.

    ***************************************************************************/

    public void relinquish ( )
    in
    {
        assert(this.t_pool !is null);
    }
    body
    {
        if ( this.acquired !is null )
            this.t_pool.recycle(this.acquired);
    }
}

///
unittest
{
    // Type of a specialised resource which may be required by requests.
    struct MyResource
    {
    }

    // Demonstrates how a typical global shared resources container should look.
    // A single instance of this would be owned at the top level of the client/
    // node.
    class SharedResources
    {
        import ocean.util.container.pool.FreeList;

        // The pool of specialised resources required by AcquiredSingleton.
        private FreeList!(MyResource) myresources;

        this ( )
        {
            this.myresources = new FreeList!(MyResource);
        }

        // Objects of this class will be newed at scope and passed to request
        // handlers. This allows the handler to acquire various shared resources
        // and have them automatically relinquished when the handler exits.
        class RequestResources
        {
            private AcquiredSingleton!(MyResource) myresource_singleton;

            // Initialise the tracker in the ctor.
            this ( )
            {
                this.myresource_singleton.initialise(this.outer.myresources);
            }

            // ...and be sure to relinquish all the acquired resources in the
            // dtor.
            ~this ( )
            {
                this.myresource_singleton.relinquish();
            }

            // Public method to get the resource singleton for this request,
            // managed by the tracker.
            public MyResource* myResource ( )
            {
                return this.myresource_singleton.acquire(new MyResource,
                    ( MyResource* resource )
                    {
                        // When the singleton is first acquired, perform any
                        // logic required to reset it to its initial state.
                        *resource = MyResource.init;
                    }
                );
            }
        }
    }
}

/*******************************************************************************

    Test that shared resources are acquired and relinquished correctly using the
    helper structs above.

*******************************************************************************/

version ( UnitTest )
{
    import ocean.core.Test;
}

unittest
{
    // Resource types that may be acquired.
    struct MyStruct { }
    class MyClass { }

    class SharedResources
    {
        import ocean.util.container.pool.FreeList;

        private FreeList!(MyStruct) mystructs;
        private FreeList!(MyClass) myclasses;
        private FreeList!(ubyte[]) buffers;

        this ( )
        {
            this.mystructs = new FreeList!(MyStruct);
            this.myclasses = new FreeList!(MyClass);
            this.buffers = new FreeList!(ubyte[]);
        }

        class RequestResources
        {
            private Acquired!(MyStruct) acquired_mystructs;
            private AcquiredSingleton!(MyStruct) mystruct_singleton;
            private Acquired!(MyClass) acquired_myclasses;
            private AcquiredArraysOf!(void) acquired_void_arrays;

            this ( )
            {
                this.acquired_mystructs.initialise(this.outer.buffers,
                    this.outer.mystructs);
                this.mystruct_singleton.initialise(this.outer.mystructs);
                this.acquired_myclasses.initialise(this.outer.buffers,
                    this.outer.myclasses);
                this.acquired_void_arrays.initialise(this.outer.buffers);
            }

            ~this ( )
            {
                this.acquired_mystructs.relinquishAll();
                this.mystruct_singleton.relinquish();
                this.acquired_myclasses.relinquishAll();
                this.acquired_void_arrays.relinquishAll();
            }

            public MyStruct* getMyStruct ( )
            {
                return this.acquired_mystructs.acquire(new MyStruct);
            }

            public MyStruct* myStructSingleton ( )
            {
                return this.mystruct_singleton.acquire(new MyStruct);
            }

            public MyClass getMyClass ( )
            {
                return this.acquired_myclasses.acquire(new MyClass);
            }

            public void[]* getVoidArray ( )
            {
                return this.acquired_void_arrays.acquire();
            }
        }
    }

    auto resources = new SharedResources;

    // Test acquiring some resources.
    {
        scope acquired = resources.new RequestResources;
        test!("==")(resources.buffers.num_idle, 0);
        test!("==")(resources.mystructs.num_idle, 0);
        test!("==")(resources.myclasses.num_idle, 0);

        // Acquire a struct.
        acquired.getMyStruct();
        test!("==")(resources.buffers.num_idle, 0);
        test!("==")(resources.mystructs.num_idle, 0);
        test!("==")(resources.myclasses.num_idle, 0);
        test!("==")(acquired.acquired_mystructs.acquired.length, 1);

        // Acquire a struct singleton twice.
        acquired.myStructSingleton();
        acquired.myStructSingleton();
        test!("==")(resources.buffers.num_idle, 0);
        test!("==")(resources.mystructs.num_idle, 0);
        test!("==")(resources.myclasses.num_idle, 0);
        test!("==")(acquired.acquired_mystructs.acquired.length, 1);

        // Acquire a class.
        acquired.getMyClass();
        test!("==")(resources.buffers.num_idle, 0);
        test!("==")(resources.mystructs.num_idle, 0);
        test!("==")(resources.myclasses.num_idle, 0);
        test!("==")(acquired.acquired_myclasses.acquired.length, 1);

        // Acquire an array.
        acquired.getVoidArray();
        test!("==")(resources.buffers.num_idle, 0);
        test!("==")(resources.mystructs.num_idle, 0);
        test!("==")(resources.myclasses.num_idle, 0);
        test!("==")(acquired.acquired_void_arrays.acquired.length, 1);
    }

    // Test that the acquired resources appear in the free-lists, once the
    // acquired tracker goes out of scope.
    test!("==")(resources.buffers.num_idle, 4); // 3 container arrays + 1
    test!("==")(resources.mystructs.num_idle, 2);
    test!("==")(resources.myclasses.num_idle, 1);

    // Now do it again and test that the resources in the free-lists are reused.
    {
        scope acquired = resources.new RequestResources;
        test!("==")(resources.buffers.num_idle, 4);
        test!("==")(resources.mystructs.num_idle, 2);
        test!("==")(resources.myclasses.num_idle, 1);

        // Acquire a struct.
        acquired.getMyStruct();
        test!("==")(resources.buffers.num_idle, 3);
        test!("==")(resources.mystructs.num_idle, 1);
        test!("==")(resources.myclasses.num_idle, 1);
        test!("==")(acquired.acquired_mystructs.acquired.length, 1);

        // Acquire a class.
        acquired.getMyClass();
        test!("==")(resources.buffers.num_idle, 2);
        test!("==")(resources.mystructs.num_idle, 1);
        test!("==")(resources.myclasses.num_idle, 0);
        test!("==")(acquired.acquired_myclasses.acquired.length, 1);

        // Acquire an array.
        acquired.getVoidArray();
        test!("==")(resources.buffers.num_idle, 0);
        test!("==")(resources.mystructs.num_idle, 1);
        test!("==")(resources.myclasses.num_idle, 0);
        test!("==")(acquired.acquired_void_arrays.acquired.length, 1);
    }

    // No more resources should have been allocated.
    test!("==")(resources.buffers.num_idle, 4); // 3 container arrays + 1
    test!("==")(resources.mystructs.num_idle, 2);
    test!("==")(resources.myclasses.num_idle, 1);
}
