/*******************************************************************************

    Helper classes to manage the situations where:
        1. You are streaming records from one or more ISuspendable sources.
        2. For each record received you wish to do some processing which will
           not finish immediately. (Thus the received records need to be kept
           around in some way, forming a set of 'pending items'.)
        3. The ISuspendables which are providing the input records must be
           throttled (i.e. suspended and resumed) based on the number of pending
           items.

    The individual classes have full usage examples. See below.

    copyright:  Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.helper.SuspendableThrottler;



/*******************************************************************************

    Imports

*******************************************************************************/

import Ocean = ocean.io.model.SuspendableThrottlerCount;
import ocean.util.container.AppendBuffer;

import swarm.client.model.IClient;
import Swarm = swarm.client.helper.model.ISuspendableThrottler;
import swarm.client.request.context.RequestContext;
import swarm.client.request.model.ISuspendableRequest;

import ocean.core.array.Search : contains;
import ocean.transition;


/*******************************************************************************

    Simple suspendable throttler which just counts the number of pending items,
    and throttles the suspendables based on that count. No data other than the
    pending count is stored.

*******************************************************************************/

public class SuspendableThrottlerCount : Ocean.SuspendableThrottlerCount
{
    public this ( size_t suspend_point, size_t resume_point )
    {
        super(suspend_point, resume_point);
    }


    /***************************************************************************

        Adds a suspendable to the list of suspendables which are to be
        throttled. If it is already in the list, nothing happens.
        Contains a context for the suspend registration.

        Params:

            c = context (unused)
            s = suspendable

    ***************************************************************************/

    public void addSuspendable ( RequestContext context, ISuspendableRequest s )
    {
        super.addSuspendable(s);
    }


    /***************************************************************************

        Adds a suspendable to the list of suspendables which are to be
        throttled. If it is already in the list, nothing happens.

        Params:

            c = context (unused)

    ***************************************************************************/

    alias Ocean.ISuspendableThrottler.addSuspendable addSuspendable;
}

/*******************************************************************************

    Class for throttling based on the fullness of an IClient's request
    queues. The throttle() method must be called manually by the user at
    appropriate points (presumably when assigning a request to the client and
    when a request has finished).

*******************************************************************************/

public class RequestQueueSuspendableThrottler : Swarm.ISuspendableThrottler
{
    /***************************************************************************

        Client whose request queue determines the throttling of the
        suspendables.

    ***************************************************************************/

    private IClient client;


    /***************************************************************************

        Fraction of client's request queue fullness at which the suspendables
        should be suspended / resumed.

    ***************************************************************************/

    private Const!(float) suspend_point;

    private Const!(float) resume_point;


    /***************************************************************************

        Constructor.

        Params:
            client = client whose request queue should be used to determine the
                throttling of the suspendables
            suspend_point = fraction of client's request queue fullness at which
                the suspendables should be suspended
            resume_point = fraction of client's request queue fullness at which
                the suspendables should be resumed

    ***************************************************************************/

    public this ( IClient client,
        float suspend_point = 0.75, float resume_point = 0.1 )
    {
        assert(suspend_point >= 0.0);
        assert(suspend_point <= 1.0);
        assert(resume_point >= 0.0);
        assert(resume_point <= 1.0);
        assert(suspend_point > resume_point);

        this.client = client;
        this.suspend_point = suspend_point;
        this.resume_point = resume_point;
    }


    /***************************************************************************

        Adds a suspendable to the list of suspendables which are to be
        throttled. If it is already in the list, nothing happens.
        Contains a context for the suspend registration.

        Params:

            c = context (unused)
            s = suspendable

    ***************************************************************************/

    override public void addSuspendable ( RequestContext context, ISuspendableRequest s )
    {
        (cast(Ocean.ISuspendableThrottler)this).addSuspendable(s);
    }


    /***************************************************************************

        Adds a suspendable to the list of suspendables which are to be
        throttled. If it is already in the list, nothing happens.

        Params:

            c = context (unused)

    ***************************************************************************/

    alias Ocean.ISuspendableThrottler.addSuspendable addSuspendable;


    /***************************************************************************

        Decides whether the suspendables should be suspended. Called by
        throttle() when not suspended.

        Returns:
            true if the suspendables should be suspeneded

    ***************************************************************************/

    override protected bool suspend ( )
    {
        return this.request_queue_fullness >= this.suspend_point;
    }


    /***************************************************************************

        Decides whether the suspendables should be resumed. Called by
        throttle() when suspended.

        Returns:
            true if the suspendables should be resumed

    ***************************************************************************/

    override protected bool resume ( )
    {
        return this.request_queue_fullness <= this.resume_point;
    }


    /***************************************************************************

        Calculates the fullness fraction of the client's request queues. In the
        case where the client has multiple nodes registered, the size of the
        fullest request queue is used.

        Returns:
            fullness fraction of client's request queues

    ***************************************************************************/

    private float request_queue_fullness ( )
    {
        size_t queued_bytes;

        foreach ( node; this.client.nodes )
        {
            if ( node.queued_bytes > queued_bytes )
            {
                queued_bytes = node.queued_bytes ;
            }
        }

        return cast(float)queued_bytes /
            cast(float)this.client.nodes.queue_limit;
    }
}
