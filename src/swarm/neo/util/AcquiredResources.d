/*******************************************************************************

    Helper structs to acquire and relinquish shared resources during the
    handling of a request.

    Copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.util.AcquiredResources;

import ocean.transition;

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

        Externally owned pool of untyped buffers, passed in via initialise().

    ***************************************************************************/

    private FreeList!(ubyte[]) buffer_pool;

    /***************************************************************************

        List of acquired buffers.

    ***************************************************************************/

    private T[][] acquired;

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

        Returns:
            a new array of T

    ***************************************************************************/

    public T[]* acquire ( )
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
            this.acquired = cast(T[][])newBuffer((T[]).sizeof * 4);
        }

        // Acquire and re-initialise new buffer to return to the user. Store
        // it in the container buffer.
        this.acquired ~= cast(T[])newBuffer(4);
        return &this.acquired[$-1];
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
            // Relinquish acquired buffers.
            foreach ( ref inst; this.acquired )
                this.buffer_pool.recycle(cast(ubyte[])inst);

            // Relinquish container buffer.
            this.buffer_pool.recycle(cast(ubyte[])this.acquired);
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
            private Acquired!(MyClass) acquired_myclasses;
            private AcquiredArraysOf!(void) acquired_void_arrays;

            this ( )
            {
                this.acquired_mystructs.initialise(this.outer.buffers,
                    this.outer.mystructs);
                this.acquired_myclasses.initialise(this.outer.buffers,
                    this.outer.myclasses);
                this.acquired_void_arrays.initialise(this.outer.buffers);
            }

            ~this ( )
            {
                this.acquired_mystructs.relinquishAll();
                this.acquired_myclasses.relinquishAll();
                this.acquired_void_arrays.relinquishAll();
            }

            public MyStruct* getMyStruct ( )
            {
                return this.acquired_mystructs.acquire(new MyStruct);
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
    test!("==")(resources.mystructs.num_idle, 1);
    test!("==")(resources.myclasses.num_idle, 1);

    // Now do it again and test that the resources in the free-lists are reused.
    {
        scope acquired = resources.new RequestResources;
        test!("==")(resources.buffers.num_idle, 4);
        test!("==")(resources.mystructs.num_idle, 1);
        test!("==")(resources.myclasses.num_idle, 1);

        // Acquire a struct.
        acquired.getMyStruct();
        test!("==")(resources.buffers.num_idle, 3);
        test!("==")(resources.mystructs.num_idle, 0);
        test!("==")(resources.myclasses.num_idle, 1);
        test!("==")(acquired.acquired_mystructs.acquired.length, 1);

        // Acquire a class.
        acquired.getMyClass();
        test!("==")(resources.buffers.num_idle, 2);
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

    // No more resources should have been allocated.
    test!("==")(resources.buffers.num_idle, 4); // 3 container arrays + 1
    test!("==")(resources.mystructs.num_idle, 1);
    test!("==")(resources.myclasses.num_idle, 1);
}
