/*******************************************************************************

    Client request stats tracker internals plus public interface.

    Copyright (c) 2017 sociomantic labs GmbH. All rights reserved.

*******************************************************************************/

module swarm.neo.client.requests.Stats;

import swarm.neo.client.IRequestSet : IRequest;

/*******************************************************************************

    Request stats methods which are publicly exposed by the RequestSet (i.e. can
    be called by the user of the client).

*******************************************************************************/

public interface IRequestStats
{
    /***************************************************************************

        Stats about a single request, together with read-only methods exposed in
        the public API of the client.

    ***************************************************************************/

    public struct RequestStats
    {
        /// The number of requests of this type that have finished.
        public ulong count;

        /// The total time (in microseconds) taken by all finished requests.
        public ulong total_time_micros;

        /***********************************************************************

            Returns:
                the mean time (in microseconds) taken by each request of this
                type (may, of course, be nan or -nan, if this.count == 0)

        ***********************************************************************/

        public double mean_handled_time_micros ( )
        {
            return cast(double)this.total_time_micros / cast(double)this.count;
        }
    }

    /// Alias for a unique identifier for a request type. (Request
    /// implementations currently have no publicly available "code" or simple
    /// means of differentiation. The type of the finished notifier function
    /// should be unique, however, so we use that as a means of uniquely
    /// identifying the type of a request.)
    private alias IRequest.FinishedNotifier RequestTypeIdentifier;

    /***************************************************************************

        Gets stats about the specified request.

        Params:
            request_type = identifier for the request to get stats about

        Returns:
            RequestStats instance pertaining to the specified request

    ***************************************************************************/

    public RequestStats requestStats ( RequestTypeIdentifier request_type );

    /***************************************************************************

        Resets all request stats to 0. (Call this after logging stats.)

    ***************************************************************************/

    public void clear ( );
}

/*******************************************************************************

    Internal stats tracker. Implements IRequestStats. Other methods are not
    exposed by the RequestSet (i.e. cannot be called by the user of the client).

*******************************************************************************/

public class Stats : IRequestStats
{
    import ocean.time.MicrosecondsClock;

    /// Map from request type identifiers -> per-request stats.
    private RequestStats[RequestTypeIdentifier] stats;

    /***************************************************************************

        Indicates that a request of the specified type has finished. Updates the
        stats tracking for that request type with the specified time.

        Params:
            request_type = type of the request which has finished
            start_time = time in microseconds at which the request started

    ***************************************************************************/

    public void requestFinished ( RequestTypeIdentifier request_type,
        ulong start_time )
    {
        auto end_time = MicrosecondsClock.now_us();
        assert(start_time <= end_time);
        auto duration = end_time - start_time;

        auto rq_stats = request_type in this.stats;
        if ( rq_stats is null )
        {
            this.stats[request_type] = RequestStats.init;
            rq_stats = request_type in this.stats;
            assert(rq_stats !is null);
        }

        rq_stats.count++;
        rq_stats.total_time_micros += duration;
    }

    /***************************************************************************

        Gets stats about the specified request.

        Params:
            request_type = identifier for the request to get stats about

        Returns:
            RequestStats instance pertaining to the specified request

    ***************************************************************************/

    public RequestStats requestStats ( RequestTypeIdentifier request_type )
    {
        if ( auto rq_stats = request_type in this.stats )
            return *rq_stats;
        else
            return RequestStats.init;
    }

    /***************************************************************************

        Resets all request stats to 0. (Call this after logging stats.)

    ***************************************************************************/

    public void clear ( )
    {
        foreach ( ref rq_stats; this.stats )
        {
            rq_stats = RequestStats.init;
        }
    }
}
