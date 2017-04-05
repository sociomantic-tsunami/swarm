/*******************************************************************************

    Stats tracked on a per-request-type level.

    Has the following usage:
        * The stats are stored in an associative array, indexed by the name of
          the request. This is public, for easy access to the stats.
        * Each request type to be tracked must first be initialised, via the
          init() method. (This is for the sake of stats logging, to ensure that
          the same metrics are being continuously logged, rather than only being
          logged after a request of a certain type has been handled.)
        * When a request is handled, the started() method should be called. When
          it finished, the finished() method should be called.
        * The stats accumulate until the resetCounters() method is called.

    Note that request stats are indexed by name, rather than by command code for
    two reasons:
        1. To avoid having to make this a template class and spread the command
           template argument throughout other objects (connection handler, node,
           etc).
        2. For convenience in stats logging. The name of the stats container can
           be used to format the name of a stats metric, without having to look
           anything up.

    Copyright: Copyright (c) 2015-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.node.request.RequestStats;

import ocean.transition;

version ( UnitTest )
{
    import ocean.core.Test;
}

public class RequestStats
{
    /***************************************************************************

        Helper class to track the distribution of ulongs between a specified
        set of "buckets", each bucket covering a range of numbers. The buckets
        tracked by the struct are defined in the constructor.

    ***************************************************************************/

    private static final class BucketDistribution
    {
        import ocean.core.array.Mutation : sort;

        /***********************************************************************

            List of the upper bounds of each bucket. The list is set in the
            constructor, sorted, and never subsequently modified.

        ***********************************************************************/

        private ulong[] bucket_limits;

        /***********************************************************************

            List of the counts of values in each bucket.

        ***********************************************************************/

        private ulong[] bucket_count;

        /***********************************************************************

            Constructor. Sets the list of bucket bounds. An extra bucket --
            covering the range from the last bucket's upper bound + 1 to
            ulong.max -- is automatically added.

            Params:
                bucket_limits = list of bucket upper bounds. May not contain
                    duplicates

        ***********************************************************************/

        public this ( ulong[] bucket_limits )
        {
            this.bucket_limits = bucket_limits.dup;
            this.bucket_limits ~= ulong.max;
            sort(this.bucket_limits);

            // No duplicates allowed
            for ( size_t i = 1; i < this.bucket_limits.length; i++ )
            {
                assert(this.bucket_limits[i] > this.bucket_limits[i-1]);
            }

            this.bucket_count.length = this.bucket_limits.length;
        }

        /***********************************************************************

            Adds a value to the distribution. A bucket is selected by finding
            the first (i.e. lowest) one whose upper bound is lower than or equal
            to the value.

            Params:
                value = new value to add

        ***********************************************************************/

        public void add ( ulong value )
        {
            foreach ( i, bucket_end; this.bucket_limits )
            {
                if ( value <= bucket_end )
                {
                    this.bucket_count[i]++;
                    return;
                }
            }
            assert(false, "value is not <= ulong.max!");
        }

        /***********************************************************************

            foreach iterator over the bucket upper bounds and the count of items
            in the buekcts.

        ***********************************************************************/

        public int opApply (
            int delegate ( ref ulong bucket_end, ref ulong count ) dg )
        {
            int ret;
            foreach ( i, count; this.bucket_count )
            {
                ret = dg(this.bucket_limits[i], count);
                if ( ret )
                    break;
            }
            return ret;
        }

        /***********************************************************************

            Clears all buckets.

        ***********************************************************************/

        public void clear ( )
        {
            foreach ( ref count; this.bucket_count )
                count = 0;
        }
    }

    unittest
    {
        void checkCounts ( istring name, BucketDistribution dist, ulong[] expected )
        {
            auto t = new NamedTest(name);
            size_t i;
            foreach ( bucket_end, count; dist )
            {
                t.test!("==")(count, expected[i]);
                i++;
            }
        }

        {
            auto dist = new BucketDistribution([10UL, 100UL, 1_000UL, 10_000UL, 100_000UL]);
            checkCounts("Initially empty", dist, [0, 0, 0, 0, 0, 0]);
        }

        {
            auto dist = new BucketDistribution([10UL, 100UL, 1_000UL, 10_000UL, 100_000UL]);
            dist.add(10);
            dist.add(100);
            dist.add(1_000);
            dist.add(10_000);
            dist.add(100_000);
            dist.add(ulong.max);
            checkCounts("Add boundaries", dist, [1, 1, 1, 1, 1, 1]);

            dist.clear();
            checkCounts("Clear", dist, [0, 0, 0, 0, 0, 0]);
        }

        {
            auto dist = new BucketDistribution([10UL, 100UL, 1_000UL, 10_000UL, 100_000UL]);
            for ( ulong i = 0; i <= 1_000; i++ ) // add 0..1000, inclusive
                dist.add(i);
            checkCounts("Add sequence", dist, [11, 90, 900, 0, 0, 0]);
        }
    }


    /***************************************************************************

        Container for stats about a single type of request.

    ***************************************************************************/

    private static final class SingleRequestStats
    {
        /***********************************************************************

            Container for stats counters.

        ***********************************************************************/

        private struct Counters
        {
            uint active;
            uint max_active;
            uint finished;
        }


        /***********************************************************************

            Stats counters for this request type.

        ***********************************************************************/

        private Counters counters;


        /***********************************************************************

            Buckets for timing distribution for this request type.

        ***********************************************************************/

        private BucketDistribution time_distribution;


        /***********************************************************************

            Total time (in microseconds) taken by requests of this type since
            the last call to resetCounters().

        ***********************************************************************/

        private ulong total_handled_time_micros;


        /***********************************************************************

            Constructor.

        ***********************************************************************/

        public this ( )
        {
            this.time_distribution =
                new BucketDistribution([10UL, 100UL, 1_000UL, 10_000UL, 100_000UL]);
        }


        /***********************************************************************

            Returns:
                number of requests of this type which are currently active

        ***********************************************************************/

        public uint active ( )
        {
            return this.counters.active;
        }


        /***********************************************************************

            Returns:
                maximum number of requests of this type which were active
                simultaneously

        ***********************************************************************/

        public uint max_active ( )
        {
            return this.counters.max_active;
        }


        /***********************************************************************

            Returns:
                number of requests of this type which were previously active

        ***********************************************************************/

        public uint finished ( )
        {
            return this.counters.finished;
        }


        /***********************************************************************

            Returns:
                the mean time in microseconds spent handling requests of this
                type

        ***********************************************************************/

        public double mean_handled_time_micros ( )
        {
            return cast(double)this.total_handled_time_micros /
                cast(double)this.counters.finished;
        }


        /***********************************************************************

            Returns:
                the number of requests of this type which took 10 microseconds
                or less to handle

        ***********************************************************************/

        public ulong handled_10_micros ( )
        {
            return this.time_distribution.bucket_count[0];
        }


        /***********************************************************************

            Returns:
                the number of requests of this type which took more than 10 and
                up to 100 microseconds to handle

        ***********************************************************************/

        public ulong handled_100_micros ( )
        {
            return this.time_distribution.bucket_count[1];
        }


        /***********************************************************************

            Returns:
                the number of requests of this type which took more than 100
                microseconds and up to 1 millisecond to handle

        ***********************************************************************/

        public ulong handled_1_ms ( )
        {
            return this.time_distribution.bucket_count[2];
        }


        /***********************************************************************

            Returns:
                the number of requests of this type which took more than 1
                millisecond and up to 10 milliseconds to handle

        ***********************************************************************/

        public ulong handled_10_ms ( )
        {
            return this.time_distribution.bucket_count[3];
        }


        /***********************************************************************

            Returns:
                the number of requests of this type which took more than 10
                milliseconds and up to 100 milliseconds to handle

        ***********************************************************************/

        public ulong handled_100_ms ( )
        {
            return this.time_distribution.bucket_count[4];
        }


        /***********************************************************************

            Returns:
                the number of requests of this type which took more than 100
                milliseconds to handle

        ***********************************************************************/

        public ulong handled_over_100_ms ( )
        {
            return this.time_distribution.bucket_count[5];
        }


        /***********************************************************************

            Called when a request of this type has started.

        ***********************************************************************/

        private void requestStarted ( )
        out
        {
            assert(this.counters.active > 0);
            assert(this.counters.active <= this.counters.max_active);
        }
        body
        {
            this.counters.active++;

            if ( this.counters.active > this.counters.max_active )
            {
                this.counters.max_active = this.counters.active;
            }
        }


        /***********************************************************************

            Called when a request of this type has finished. Timing stats are
            not known and not updated.

        ***********************************************************************/

        private void requestFinished ( )
        in
        {
            assert(this.counters.active > 0);
        }
        body
        {
            this.counters.active--;
            this.counters.finished++;
        }


        /***********************************************************************

            Called when a request of this type has finished and we know how long
            it took to handle. The timing stats are updated.

            Params:
                microseconds = time taken to handle the request

        ***********************************************************************/

        private void requestFinished ( ulong microseconds )
        {
            this.requestFinished();

            this.time_distribution.add(microseconds);
            this.total_handled_time_micros += microseconds;
        }


        /***********************************************************************

            Resets the stats counters for this type of request:
                * counters.active is not modified -- it is updated only by the
                  requestStarted() and requestFinished() methods.
                * counters.finished is cleared -- it's a simple counter of
                  events which occurred since the last reset.
                * counters.max_active is set to the current value of
                  counters.active -- entering the new stats tracking period
                  (i.e. resetCounters() being called), the maximum number of
                  active requests of this type is equal to the number which are
                  currently active.

        ***********************************************************************/

        private void resetCounters ( )
        {
            this.counters.finished = 0;
            this.counters.max_active = this.counters.active;
            this.time_distribution.clear();
            this.total_handled_time_micros = 0;
        }
    }


    /***************************************************************************

        Map of per-request stats, indexed by name of request.

    ***************************************************************************/

    public SingleRequestStats[istring] request_stats;


    /***************************************************************************

        Initialises the specific request type for stats tracking.

        Params:
            rq = name of request

    ***************************************************************************/

    public void init ( istring rq )
    {
        assert(!(rq in this.request_stats), "command stats " ~ rq ~ " initialised twice");

        this.request_stats[rq] = new SingleRequestStats;
    }


    /***************************************************************************

        To be called when a request of the specified type starts. The request
        type must already have been initialised (see init()).

        Params:
            rq = name of request

    ***************************************************************************/

    public void started ( cstring rq )
    {
        auto stats = rq in this.request_stats;
        assert(stats, "command stats " ~ rq ~" not initialised");

        stats.requestStarted();
    }


    /***************************************************************************

        To be called when a request of the specified type finishes. The request
        type must already have been initialised (see init()). Timing stats are
        not known and not updated.

        Params:
            rq = name of request

    ***************************************************************************/

    public void finished ( cstring rq )
    {
        auto stats = rq in this.request_stats;
        assert(stats, "command stats " ~ rq ~" not initialised");

        stats.requestFinished();
    }


    /***************************************************************************

        To be called when a request of the specified type finishes and we know
        how long it took to handle. The timing stats are updated. The request
        type must already have been initialised (see init()).

        Params:
            rq = name of request
            microseconds = time taken to handle the request

    ***************************************************************************/

    public void finished ( cstring rq, ulong microseconds )
    {
        auto stats = rq in this.request_stats;
        assert(stats, "command stats " ~ rq ~ " not initialised");

        stats.requestFinished(microseconds);
    }


    /***************************************************************************

        Resets the accumulated stats for all request types.

    ***************************************************************************/

    public void resetCounters ( )
    {
        foreach ( ref stats; this.request_stats )
        {
            stats.resetCounters();
        }
    }
}

