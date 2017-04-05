/*******************************************************************************

    Client request timeout manager.

    Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved.

*******************************************************************************/

module swarm.neo.client.requests.Timeouts;

/// ditto
public class Timeouts
{
    import swarm.neo.client.IRequestSet;
    import ocean.io.select.client.TimerSet;
    import swarm.neo.protocol.Message: RequestId;
    import swarm.neo.util.FixedSizeMap;
    import ocean.io.select.EpollSelectDispatcher;

    /// Alias for a set of timers associated with request ids.
    private alias TimerSet!(RequestId) TimeoutSet;

    /// Set of timers associated with request ids. (This timer set could be
    /// extended to be used for other purposes, e.g. request scheduling.)
    private TimeoutSet timeouts;

    /// Alias for a map of request ids -> scheduled timeout events.
    private alias FixedSizeMap!(TimeoutSet.IEvent, RequestId) RequestMap;

    /// Map of request ids -> scheduled timeout events.
    private RequestMap timeout_requests;

    /// Alias for a delegate to call to abort a request when it times out.
    private alias void delegate ( RequestId ) AbortRequestDg;

    /// Delegate to be called to abort a request when it times out.
    private AbortRequestDg abort_request;

    /***************************************************************************

        Constructor.

        Params:
            epoll = epoll instance used to register the timer event which
                fires when a timeout occurs

    ***************************************************************************/

    public this ( EpollSelectDispatcher epoll, AbortRequestDg abort_request )
    {
        this.timeouts = new TimeoutSet(epoll);
        this.timeout_requests = new RequestMap(IRequestSet.max_requests);
        this.abort_request = abort_request;
    }

    /***************************************************************************

        Sets the request with the specified id to timeout after the
        specified number of microseconds. If the request finishes before the
        timeout occurs, the clearRequestTimeout() method should be called,
        to avoid useless firing of timeouts for requests which no longer
        exist.

        Params:
            id = id of request to set a timeout for
            timeout_micros = microseconds timeout value to set

    ***************************************************************************/

    public void setRequestTimeout ( RequestId id, ulong timeout_micros )
    {
        auto event = this.timeouts.schedule(
            ( ref RequestId timeout_id )
            {
                timeout_id = id;
            },
            &this.timeoutCallback,
            timeout_micros
        );

        *this.timeout_requests.add(id) = event;
    }

    /***************************************************************************

        Clears the timeout for the request with the specified id, if it is
        registered to timeout. (Otherwise, does nothing.)

        Params:
            id = id of request to clear the timeout for

    ***************************************************************************/

    public void clearRequestTimeout ( RequestId id )
    {
        if ( auto event = id in this.timeout_requests )
        {
            event.unregister(); // removes from the timeout set
            this.timeout_requests.removeExisting(id);
        }
    }

    /***************************************************************************

        Called when a timeout occurs for the specified request. Aborts the
        request.

        Params:
            id = id of request which timed out

    ***************************************************************************/

    private void timeoutCallback ( ref RequestId id )
    {
        this.timeout_requests.removeExisting(id);
        assert(!(id in this.timeout_requests));

        this.abort_request(id);
    }
}
