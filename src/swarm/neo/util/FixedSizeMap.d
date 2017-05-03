/*******************************************************************************

    Hash map with a fixed maximum size and enforcing adding only new and
    removing only existing elements. The bucket elements are allocated in one
    array, and the map serves as a pool for the values.

    Copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.util.FixedSizeMap;

/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.util.container.map.Map;

/******************************************************************************/

class FixedSizeMap ( V, K ) : StandardKeyHashingMap!(V, K)
{
    import ocean.util.container.map.model.BucketElementFreeList;
    import ocean.text.util.ClassName;

    /***************************************************************************

        Bucket elements allocator.

    ***************************************************************************/

    private BucketElementPool pool;

    /***************************************************************************

        Constructor.

        Params:
            n = maximum number of elements in mapping and pool size

    ***************************************************************************/

    public this ( size_t n )
    {
        super(this.pool = new BucketElementPool(n), n);
    }

    /***************************************************************************

        Adds a new element to the map, asserting that
          - a mapping for key does not already exist and
          - the map does not already contain n elements where n is the  maximum
            number of elements passed to the constructor.

        Params:
            key = the key of the mapping to add

        Returns:
            a pointer to the value in the map associated with key. The value may
            be an old value that has previously been added and removed.

    ***************************************************************************/

    public V* add ( K key )
    {
        bool was_added;
        auto val_ptr = this.put(key, was_added);
        assert(was_added, typeof(this).stringof ~
                             ".add: element already in map");
        return val_ptr;
    }

    /***************************************************************************

        Removes an element from the map, asserting that a mapping for key
        exists. Keeps the associated value in the pool to be reused later when
        adding a new element.

        Params:
            key     = the key of the mapping to remove
            removed = optional callback delegate, called with the removed value.

    ***************************************************************************/

    public void removeExisting ( K key, void delegate ( ref V val ) removed = null )
    {
        bool was_present = this.remove(key, removed);
        assert(was_present, typeof(this).stringof ~
                            ".removeExisting: element not found");
    }

    /**************************************************************************/

    static class BucketElementPool: BucketElementFreeList!(Bucket.Element)
    {
        /***********************************************************************

            Preallocated pool of bucket elements.

        ***********************************************************************/

        private Bucket.Element[] items;

        /***********************************************************************

            The number of bucket elements currently used.

        ***********************************************************************/

        private size_t n = 0;

        /***********************************************************************

            Constructor.

            Params:
                n = number of elements in the pool

        ***********************************************************************/

        private this ( size_t n )
        {
            this.items = new Bucket.Element[n];
        }

        /***********************************************************************

            Obtains a new element from the pool.

            Returns:
                A new pool element.

        ***********************************************************************/

        protected override Bucket.Element* newElement ( )
        {
            assert(this.n < this.items.length, typeof(this).stringof ~
                   "maximum number of elements exceeded");
            return &this.items[this.n++];
        }
    }
}

