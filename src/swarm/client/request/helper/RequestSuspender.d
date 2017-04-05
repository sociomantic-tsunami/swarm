/*******************************************************************************

    Helper class for a request which can be suspended and resumed.

    copyright:      Copyright (c) 2012-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.request.helper.RequestSuspender;



/*******************************************************************************

    Imports

*******************************************************************************/

import swarm.client.request.model.ISuspendableRequest;

import ocean.io.select.client.FiberSelectEvent;

import swarm.client.request.context.RequestContext;

import swarm.Const : NodeItem;


/*******************************************************************************

    Suspendable request class. Helper class which provides the internal
    machinery for a fiber-based async request which can be suspended & resumed.

    A request class using RequestSuspender should do the following:

        1. When the request handler begins it should call RequestSuspender.start().
        2. When the request handler reaches a point where it might want to
           suspend, it should call RequestSuspender.handleSuspension().

*******************************************************************************/

public class RequestSuspender : ISuspendableRequest
{
    /***************************************************************************

        Convenience access to NodeItem

    ***************************************************************************/

    protected alias .NodeItem NodeItem;

    /***************************************************************************

        Convinience access to RequestContext

    ***************************************************************************/

    protected alias .RequestContext RequestContext;

    /***************************************************************************

        Selector event used to trigger the resumption of the request.

        Note that the event instance is not const, as it is occasionally useful
        to be able to change the event after construction. An example of this
        use case would be when a request suspender instance is created for use
        with a request, but then, some time later, needs to be re-used for a
        different request - necessitating an event switch.

    ***************************************************************************/

    public FiberSelectEvent event;


    /**************************************************************************

        The event must always be non-null.

     **************************************************************************/

    invariant ()
    {
        assert(this.event !is null, typeof(this).stringof ~ " event is null");
    }


    /***************************************************************************

        Flag indicating whether the suspendable is currently suspended.

    ***************************************************************************/

    private bool suspended_;


    /***************************************************************************

        Flag indicating whether the suspension has been requested.

    ***************************************************************************/

    private bool suspend_requested;

    /***************************************************************************

        Information about the node that this suspender belongs to

    ***************************************************************************/

    public NodeItem nodeitem_;

    /***************************************************************************

        Context object

    ***************************************************************************/

    public RequestContext context_;

    /***************************************************************************

        Constructor.

        Params:
            event = fiber to suspend / resume with event wait / trigger
            nodeitem = information about the node that this suspenders command
                       is associated with
            c        = initial request context

    ***************************************************************************/

    public this ( FiberSelectEvent event, NodeItem nodeitem, RequestContext c )
    {
        this.event = event;
        this.context_ = c;
        this.nodeitem_ = nodeitem;
    }


    /***************************************************************************

        Should be called when the request handler begins.

    ***************************************************************************/

    public void start ( )
    {
        this.suspended_ = false;
        this.suspend_requested = false;
    }


    /***************************************************************************

        ISuspendable interface method. Requests that processing be suspended.
        After the next value is received the receiver is unregistered from
        epoll, and the resume event is registered in its place.

    ***************************************************************************/

    public void suspend ( )
    {
        this.suspend_requested = true;
    }


    /***************************************************************************

        ISuspendable interface method. Resumes the request by triggering the
        custom event. When the event is handled it re-registers the receiver.

    ***************************************************************************/

    public void resume ( )
    {
        if ( this.suspended_ )
        {
            this.event.trigger();
        }

        this.suspend_requested = false;
    }


    /***************************************************************************

        ISuspendable interface method.

        Returns:
            true if the process is suspended (or a suspend has been requested)

    ***************************************************************************/

    public bool suspended ( )
    {
        return this.suspended_;
    }


    /***************************************************************************

        Should be called by the user when the request handler reaches a point
        where it has processed all received data, and wishes to suspend if this
        has been requested. Checks whether suspension has been requested, and if
        so sets the state to Suspended and waits for the resume event to be
        triggered.

        Returns:
            true if the request was suspended

    ***************************************************************************/

    public bool handleSuspension ( )
    {
        if ( this.suspend_requested )
        {
            this.suspended_ = true;

            this.event.wait;

            this.suspended_ = false;

            return true;
        }

        return false;
    }


    /***************************************************************************

        Returns:
            the context set for this producer

    ***************************************************************************/

    public override RequestContext context ( )
    {
        return this.context_;
    }


    /***************************************************************************

        Returns:
            the nodeitem this producer is associated with

    ***************************************************************************/

    public override NodeItem nodeitem ( )
    {
        return this.nodeitem_;
    }
}
