/*******************************************************************************

    Node record action counters

    Maintains a collections of counters intended to count transactions which
    involve records associated with the identifier. (For example, the counter
    associated with an identifier "write" may be used to track records written
    to the storage engine in response to various requests, or a counter with the
    identifier "iterate" may track records iterated over.)

    Each counter is associated with an unique identifier string and consists of
    two values:
     - a record count which is incremented by 1 per action and
     - a byte count which is incremented by the byte length of the record
       handled by that action.

    The number of counters and the identifier strings are specified in the
    constructor and cannot be changed.

    copyright:      Copyright (c) 2015-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

******************************************************************************/

module swarm.node.model.RecordActionCounters;

import ocean.transition;

/******************************************************************************/

public class RecordActionCounters
{
    /***************************************************************************

        The counter.

    ***************************************************************************/

    public struct Counter
    {
        public uint  records;
        public ulong bytes;
    }

    /***************************************************************************

        The map (collection) of counters by identifier string.

    ***************************************************************************/

    private Counter[istring] counters;

    /***************************************************************************

        Constructor, creates the collection of counters. From this point on
        counters cannot be added or removed, nor can their identifiers be
        changed.

        Params:
            ids = counter IDs

    ***************************************************************************/

    package this ( in cstring[] ids )
    {
        foreach (id; ids)
        {
            this.counters[idup(id)] = Counter.init;
        }

        this.counters.rehash;
    }

    /***************************************************************************

        Counts an action by incrementing the counter associated with id.

        Params:
            id    = counter identifier, must be one of the identifiers passed to
                    the constructor
            bytes = the length of the record(s) that were handled by the action
                    in bytes
            records = the number of records handled

    ***************************************************************************/

    public void increment ( cstring id, ulong bytes, ulong records = 1 )
    {
        Counter* counter = id in this.counters;

        assert(counter, "unknown counter id '" ~ id ~ "'");

        counter.records += records;
        counter.bytes += bytes;
    }

    /***************************************************************************

        Returns the values of the counter associated with id.

        Params:
            id = counter identifier, must be one of the identifiers passed to
                 the constructor

        Returns:
            the values of the counter associated with id.

    ***************************************************************************/

    public Counter opIndex ( cstring id )
    {
        return this.counters[id];
    }

    /***************************************************************************

        Resets all counters in the collection.

    ***************************************************************************/

    public void reset ( )
    {
        foreach (ref amount; this.counters)
        {
            amount = amount.init;
        }
    }

    /***************************************************************************

        'foreach' iteration over the counter ids and values.

    ***************************************************************************/

    public int opApply ( int delegate ( ref istring id, ref Counter counter ) dg )
    {
        foreach (id, counter; this.counters)
        {
            if (int x = dg(id, counter)) return x;
        }

        return 0;
    }
}


/******************************************************************************/

version (UnitTest)
{
    import ocean.core.Test;

    unittest
    {
        alias RecordActionCounters.Counter Counter;

        scope sc = new RecordActionCounters(["eggs"[], "bacon", "spam"]);

        void testCounters ( Counter eggs, Counter bacon, Counter spam,
                            istring file = __FILE__, int line = __LINE__  )
        {
            test!("==")(sc["eggs"], eggs, file, line);
            test!("==")(sc["bacon"], bacon, file, line);
            test!("==")(sc["spam"], spam, file, line);

            foreach (id, counter; sc)
            {
                switch (id)
                {
                    case "eggs":
                        test!("==")(counter, eggs, file, line);
                        break;

                    case "bacon":
                        test!("==")(counter, bacon, file, line);
                        break;

                    case "spam":
                        test!("==")(counter, spam, file, line);
                        break;

                    default:
                        test(false, "unknown counter id '" ~ id ~ "'");
                }
            }
        }

        testCounters(Counter(0, 0), Counter(0, 0), Counter(0, 0));

        sc.increment("bacon", 47);
        sc.increment("eggs", 11);

        testCounters(Counter(1, 11), Counter(1, 47), Counter(0, 0));

        sc.increment("spam", 123);
        sc.increment("bacon", 456);

        testCounters(Counter(1, 11), Counter(2, 47 + 456), Counter(1, 123));

        sc.reset();

        testCounters(Counter(0, 0), Counter(0, 0), Counter(0, 0));
    }
}
