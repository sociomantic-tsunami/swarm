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

    Copyright: Copyright (c) 2015-2017 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.node.request.RequestStats;

import ocean.core.Verify;
import ocean.meta.types.Qualifiers;

version ( unittest )
{
    import ocean.core.Test;
}


/*******************************************************************************

    Interface for the stats tracked for a single request type.

*******************************************************************************/

public interface ISingleRequestStats
{
    /***************************************************************************

        Returns:
            number of requests of this type which are currently active

    ***************************************************************************/

    public uint active ( );

    /***************************************************************************

        Returns:
            maximum number of requests of this type which were active
            simultaneously

    ***************************************************************************/

    public uint max_active ( );

    /***************************************************************************

        Returns:
            number of requests of this type which were previously active

    ***************************************************************************/

    public uint finished ( );
}


/*******************************************************************************

    Interface for the stats tracked for a single request type, including timing.

*******************************************************************************/

public interface ISingleRequestStatsWithTiming : ISingleRequestStats
{
    /***************************************************************************

        Returns:
            the mean time in microseconds spent handling requests of this
            type

    ***************************************************************************/

    public double mean_handled_time_micros ( );

    /***************************************************************************

        Returns:
            the number of requests of this type which took 10 microseconds
            or less to handle

    ***************************************************************************/

    public ulong handled_10_micros ( );

    /***************************************************************************

        Returns:
            the number of requests of this type which took more than 10 and
            up to 100 microseconds to handle

    ***************************************************************************/

    public ulong handled_100_micros ( );

    /***************************************************************************

        Returns:
            the number of requests of this type which took more than 100
            microseconds and up to 1 millisecond to handle

    ***************************************************************************/

    public ulong handled_1_ms ( );

    /***************************************************************************

        Returns:
            the number of requests of this type which took more than 1
            millisecond and up to 10 milliseconds to handle

    ***************************************************************************/

    public ulong handled_10_ms ( );

    /***************************************************************************

        Returns:
            the number of requests of this type which took more than 10
            milliseconds and up to 100 milliseconds to handle

    ***************************************************************************/

    public ulong handled_100_ms ( );

    /***************************************************************************

        Returns:
            the number of requests of this type which took more than 100
            milliseconds to handle

    ***************************************************************************/

    public ulong handled_over_100_ms ( );
}


/*******************************************************************************

    Request stats tracker.

*******************************************************************************/

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
                verify(this.bucket_limits[i] > this.bucket_limits[i-1]);
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
            scope int delegate ( ref ulong bucket_end, ref ulong count ) dg )
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

    private static class SingleRequestStats : ISingleRequestStats
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

            Called when a request of this type has started.

        ***********************************************************************/

        public void requestStarted ( )
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

        public void requestFinished ( )
        {
            verify(this.counters.active > 0);
            this.counters.active--;
            this.counters.finished++;
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

        public void resetCounters ( )
        {
            this.counters.finished = 0;
            this.counters.max_active = this.counters.active;
        }
    }


    /***************************************************************************

        Container for stats about a single type of request, including timing.

    ***************************************************************************/

    private static class SingleRequestStatsWithTiming : SingleRequestStats,
        ISingleRequestStatsWithTiming
    {
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

            Called when a request of this type has finished and we know how long
            it took to handle. The timing stats are updated.

            Params:
                microseconds = time taken to handle the request

        ***********************************************************************/

        public void requestFinished ( ulong microseconds )
        {
            super.requestFinished();

            this.time_distribution.add(microseconds);
            this.total_handled_time_micros += microseconds;
        }


        /***********************************************************************

            Resets the stats counters for this type of request:
                * Performs the super class' reset logic.
                * Clears the request time distribution.
                * Resets the count of total handling time.

        ***********************************************************************/

        override public void resetCounters ( )
        {
            super.resetCounters();

            this.time_distribution.clear();
            this.total_handled_time_micros = 0;
        }
    }


    /***************************************************************************

        Map of per-request stats, indexed by name of request.

    ***************************************************************************/

    public ISingleRequestStats[istring] request_stats;


    /***************************************************************************

        Initialises the specific request type for stats tracking.

        Params:
            rq = name of request
            timing = if true, timing stats will be tracked about the request
                type (an instance of SingleRequestStatsWithTiming will be newed)

    ***************************************************************************/

    public void init ( istring rq, bool timing = true )
    {
        verify(!(rq in this.request_stats), "command stats " ~ rq ~ " initialised twice");

        if ( timing )
            this.request_stats[rq] = new SingleRequestStatsWithTiming;
        else
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
        auto stats_i = rq in this.request_stats;
        verify(stats_i !is null, idup("command stats " ~ rq ~" not initialised"));

        auto stats = cast(SingleRequestStats)*stats_i;
        verify(stats !is null);

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
        auto stats_i = rq in this.request_stats;
        verify(stats_i !is null, idup("command stats " ~ rq ~" not initialised"));

        auto stats = cast(SingleRequestStats)*stats_i;
        verify(stats !is null);

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
        auto stats_i = rq in this.request_stats;
        verify(stats_i !is null, idup("command stats " ~ rq ~" not initialised"));

        auto timed_stats = cast(SingleRequestStatsWithTiming)*stats_i;
        verify(timed_stats !is null);

        timed_stats.requestFinished(microseconds);
    }


    /***************************************************************************

        Resets the accumulated stats for all request types.

    ***************************************************************************/

    public void resetCounters ( )
    {
        foreach ( stats_i; this.request_stats )
        {
            auto stats = cast(SingleRequestStats)stats_i;
            verify(stats !is null);

            stats.resetCounters();
        }
    }

    /// Struct encapsulating API for tracking requests that are scheduled for
    /// removal.
    public struct ScheduledForRemoval
    {
        import core.stdc.time : time_t, time;
        import ocean.io.digest.Fnv1;
        import swarm.neo.AddrPort;

        import ocean.util.log.Logger;

        /// Logger for info on requests that are scheduled for removal.
        private static Logger logger;

        /// Static ctor. Initialises the logger.
        static this ( )
        {
            logger = Log.lookup("ScheduledForRemoval");
        }

        /// Tracks information about when a specific client sent a specific
        /// scheduled-for-removal request.
        private struct ClientRequestInfo
        {
            /// Indicates whether any recent activity has occurred for this
            /// client/request pair. (We use this flag to essentially remove
            /// items from the map (`client_request_info`, below), rather than
            /// using the memory-leaky AA remove operation.)
            private bool recent_activity;

            /// The number of requests of the specified type that are active for
            /// the specified client.
            private ulong active_count;

            /// Timestamp of the last activity (start, stop) of this request
            /// type for this client.
            private time_t last_activity;

            /// Seconds in an hour.
            private static enum one_hour = 60 * 60;

            invariant ( )
            {
                if ( this.active_count )
                    assert(this.recent_activity);
            }

            /*******************************************************************

                Called when a request sent by this client has started to be
                handled.

                Params:
                    now = current timestamp

            *******************************************************************/

            public void started ( time_t now )
            {
                this.hadActivity(now);
                this.active_count++;
            }

            /*******************************************************************

                Called when a request sent by this client has finished being
                handled.

                Params:
                    now = current timestamp

            *******************************************************************/

            public void finished ( time_t now )
            {
                this.hadActivity(now);
                verify(this.active_count > 0);
                this.active_count--;
            }

            /*******************************************************************

                Checks whether this client has had activity with this request
                within the last hour.

                Params:
                    now = current timestamp

                Returns:
                    true if this client has had activity with this request
                    within the last hour

            *******************************************************************/

            public bool active_this_hour ( time_t now )
            {
                return this.timeSinceLastActivity(now) <= one_hour;
            }

            /*******************************************************************

                Checks whether this client had activity with this request in the
                previous hour (i.e. > 1 hour ago, <= 2 hours ago), but no longer
                has activity with this request. Note that this is an
                edge-triggered condition, and will only return true once when
                the condition is true.

                Params:
                    now = current timestamp

                Returns:
                    true if this client had activity with this request in the
                    previous hour, but no longer

            *******************************************************************/

            public bool activity_stopped ( time_t now )
            {
                if ( this.recent_activity )
                    return false;

                auto time_since_activity = this.timeSinceLastActivity(now);
                if ( time_since_activity > one_hour &&
                    time_since_activity <= (2 * one_hour) )
                {
                    this.recent_activity = false;
                    return true;
                }
                else
                    return false;
            }

            /*******************************************************************

                Called when any kind of activity for this request/client pair
                occurs.

                Params:
                    now = current timestamp

            *******************************************************************/

            private void hadActivity ( time_t now )
            {
                this.last_activity = now;
                this.recent_activity = true;
            }

            /*******************************************************************

                Calculates the time since the last activity of this
                request/client pair.

                Params:
                    now = current timestamp

                Returns:
                    time since the last activity. If a request is currently
                    active, returns 0

            *******************************************************************/

            private time_t timeSinceLastActivity ( time_t now )
            {
                return this.active_count ? 0 : now - this.last_activity;
            }
        }

        /// Encapsulates the name of a client and the name of a scheduled-for-
        /// removal request that the client sent to the node.
        private struct ClientRequest
        {
            /// Scheduled-for-removal request that was sent.
            cstring request;

            /// Name of the client that sent the request.
            cstring client;

            /*******************************************************************

                Struct hashing function. Required for use as an AA key in D1 and
                D2.

                Returns:
                    hash of this instance

            *******************************************************************/

            public hash_t toHash ( ) const nothrow @safe
            {
                return Fnv1a.combined(this.request, this.client);
            }

            /*******************************************************************

                Struct equality function. Required for use as an AA key in D2.

                Params:
                    rhs = other instance to compare against

                Returns:
                    true if rhs is equal to this instance

            *******************************************************************/

            bool opEquals ( const typeof(this) rhs ) const
            {
                return this.request == rhs.request && this.client == rhs.client;
            }

            /*******************************************************************

                Struct comparison function. Required for use as an AA key in D1.

                TODO: can be removed, when we ditch D1.

                Params:
                    rhs = other instance to compare against

                Returns:
                    0 if rhs is equal to this instance, 1 otherwise

            *******************************************************************/

            int opCmp ( const typeof(this) rhs ) const
            {
                return this.request != rhs.request || this.client != rhs.client;
            }
        }

        /// Per-client/request information map.
        private ClientRequestInfo[ClientRequest] client_request_info;

        /***********************************************************************

            Called when a scheduled-for-removal request starts to be handled.

            Params:
                rq = name of request
                client = name of client that sent the request
                addr = remote addr/port of client

        ***********************************************************************/

        public void started ( cstring rq, cstring client, AddrPort addr )
        {
            auto now = time(null);
            auto cl_rq = ClientRequest(client, rq);
            auto info = cl_rq in this.client_request_info;
            if ( info is null )
            {
                this.client_request_info[ClientRequest(client.dup, rq.dup)]
                    = ClientRequestInfo.init;
                info = cl_rq in this.client_request_info;
            }
            assert(info !is null);

            // Warn the first time a client sends an old request version (and
            // again every hour).
            if ( !info.active_this_hour(now) )
                logger.warn("Client '{}' on {}:{} sent an old version of request '{}'",
                    client, addr.address_bytes, addr.port, rq);

            info.started(now);
        }

        /***********************************************************************

            Called when a scheduled-for-removal request stop being handled.

            Params:
                rq = name of request
                client = name of client that sent the request

        ***********************************************************************/

        public void finished ( cstring rq, cstring client )
        {
            auto now = time(null);
            auto cl_rq = ClientRequest(client, rq);
            auto info = cl_rq in this.client_request_info;
            verify(info !is null);

            info.finished(now);
        }

        /***********************************************************************

            Performs two functions:
                1. Logs when no scheduled-for-removal requests have been
                   handled for a specific client in the last hour.
                2. Returns whether a scheduled-for-removal request has been
                   handled for *any* client in the last hour.

            Returns:
                true if a scheduled-for-removal request has been handled for
                any client in the last hour; false otherwise

        ***********************************************************************/

        public bool log ( )
        {
            auto now = time(null);

            // Log when a client has no activity with a request for an hour.
            bool activity_in_last_hour;
            foreach ( names, ref info; this.client_request_info )
            {
                if ( info.active_this_hour(now) )
                    activity_in_last_hour = true;
                else if ( info.activity_stopped(now) )
                    logger.info("Client '{}' has had no activity with old versions of request '{}' in the last hour",
                        names.request, names.client);
            }

            return activity_in_last_hour;
        }
    }

    /// API for tracking stats about request that are scheduled for removal.
    public ScheduledForRemoval scheduled_for_removal;
}
