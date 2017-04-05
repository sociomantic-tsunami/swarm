/*******************************************************************************

    Class template for client plugin which adds request scheduling capabilities.

    The code inside the Extension template (see below) is mixed into the client.

    copyright:      Copyright (c) 2012-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.plugins.RequestScheduler;



/*******************************************************************************

    Imports

*******************************************************************************/

import swarm.client.model.IClient;

import swarm.client.ClientExceptions;

import swarm.client.request.params.IRequestParams;

import ocean.io.select.EpollSelectDispatcher;

import ocean.io.select.client.TimerSet;

import swarm.Const;

import swarm.client.request.notifier.IRequestNotification;

import ocean.transition;

/*******************************************************************************

    Client scheduler plugin class template.

*******************************************************************************/

public class RequestScheduler
{
    /***************************************************************************

        Local type redefinitions.

    ***************************************************************************/

    protected alias .EpollSelectDispatcher EpollSelectDispatcher;


    /***************************************************************************

        Reused "Scheduler Queue Full" exception instance.

    ***************************************************************************/

    protected SchedulerQueueFullException scheduler_queue_full;


    /***************************************************************************

        Request timer set instance

    ***************************************************************************/

    private alias TimerSet!(void[]) RequestScheduler;

    protected RequestScheduler scheduler;


    /***************************************************************************

        Delegate used to assign a request params when the scheduled time is 0.
        (See schedule().)

    ***************************************************************************/

    private alias void delegate ( IRequestParams ) AssignParamsDg;

    private AssignParamsDg assign_params;


    /***************************************************************************

        Delegate used to assign a request params when it fires in the scheduler.

    ***************************************************************************/

    private alias void delegate ( ubyte[] ) AssignScheduledRequestDg;

    private AssignScheduledRequestDg assign_scheduled_request;


    /***************************************************************************

        Constructor.

        Params:
            epoll      = epoll select dispatcher to use
            max_events = limit on the number of events which can be managed
                         by the scheduler at one time. (0 = no limit)

    ***************************************************************************/

    public this ( EpollSelectDispatcher epoll, uint max_events = 0 )
    {
        this.scheduler = new RequestScheduler(epoll, max_events);

        this.scheduler_queue_full = new SchedulerQueueFullException;
    }


    /***************************************************************************

        Schedules a new request to be assigned to the client after the given
        number of milliseconds. When the specified time elapses, the request is
        assigned in exactly the same way as if it had been sent to the assign()
        method.

        If the given number of milliseconds is 0, the request is assigned
        immediately, without going through the scheduler.

        When a request is scheduled, its serialize() method is called, and the
        serialized params stored in the scheduler. This serialized data is then
        removed and passed to the assign_scheduled_request delegate when the
        request fires in the scheduler.

        Note that if a maximum size for the scheduler's queue was specified in
        the constructor, this method may fail to schedule the request. In this
        case the request's notifier is called immediately with an exception of
        type SchedulerQueueFullException.

        Params:
            params = params of request to schedule
            assign_params = delegate which assigns the request immediately, used
                if schedule_ms is 0
            assign_scheduled_request = delegate which assigns a scheduled
                request when it fires, from the serialized data of the request
            schedule_ms = (minimum) milliseconds before request will be
                assigned

    ***************************************************************************/

    public void schedule ( IRequestParams params, AssignParamsDg assign_params,
        AssignScheduledRequestDg assign_scheduled_request, uint schedule_ms )
    {
        if ( schedule_ms == 0 )
        {
            assign_params(params);
        }
        else
        {
            if ( this.scheduleParams(params, assign_scheduled_request,
                schedule_ms) )
            {
                params.notify(null, 0, null, IStatusCodes.E.Undefined,
                    IRequestNotification.Type.Scheduled);
            }
            else
            {
                params.notify(null, 0, this.scheduler_queue_full,
                    IStatusCodes.E.Undefined, IRequestNotification.Type.Finished);
            }
        }
    }


    /***************************************************************************

        Adds a request to the scheduler. Its serialize() method is called, and
        the serialized params stored in the scheduler. This serialized data is
        then removed and passed to the assign_scheduled_request delegate when
        the request fires in the scheduler.

        Note that if a maximum size for the scheduler's queue was specified
        in the constructor, this method may fail to schedule the request. In
        this case the the method returns false.

        Params:
            params = request params to schedule
            assign_scheduled_request = delegate which assigns a scheduled
                request when it fires, from the serialized data of the request
            schedule_ms = (minimum) milliseconds before request will be
                assigned

        Returns:
            true if the request was scheduled

    ***************************************************************************/

    protected bool scheduleParams ( IRequestParams params,
        AssignScheduledRequestDg assign_scheduled_request, uint schedule_ms )
    {
        try
        {
            void setupScheduledRequest ( ref void[] scheduled_data )
            {
                scheduled_data.length = params.serialized_length;
                enableStomping(scheduled_data);
                params.serialize(cast(ubyte[])scheduled_data);
            }

            this.assign_scheduled_request = assign_scheduled_request;

            this.scheduler.schedule(&setupScheduledRequest,
                    &this.scheduledRequestFired, schedule_ms * 1000);

            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }


    /***************************************************************************

        Called when a scheduled request is ready to be assigned. Assigns the
        request.

        Params:
            params = request params

    ***************************************************************************/

    private void scheduledRequestFired ( ref void[] scheduled_data )
    in
    {
        assert (this.assign_scheduled_request !is null);
    }
    body
    {
        this.assign_scheduled_request(cast(ubyte[])scheduled_data);
    }


    /***************************************************************************

        Code to be mixed into the client.

    ***************************************************************************/

    template Extension ( istring instance )
    {
        /***********************************************************************

            Imports needed by mixin.

        ***********************************************************************/

        import swarm.client.helper.GroupRequest;


        /***********************************************************************

            Schedules a new request to be assigned to the client after the given
            number of milliseconds. When the specified time elapses, the request
            is assigned in exactly the same way as if it had been sent to the
            assign() method.

            If the given number of milliseconds is 0, the request is assigned
            immediately, without going through the scheduler.

            Note that if a maximum size for the scheduler's queue was specified
            in the scheduler's constructor, this method may fail to schedule the
            request. In this case the request's notifier is called immediately
            with an exception describing the failure.

            Template params:
                T = request type (should be one of the structs returned by the
                    command methods of the client class)

            Params:
                request = request to schedule
                schedule_ms = (minimum) milliseconds before request will be
                    assigned

        ***********************************************************************/

        public void schedule ( T ) ( T request, uint schedule_ms )
        {
            static if (is (T : IGroupRequest))
            {
                request.setClient(this);
            }

            this.scopeRequestParams(
                ( IRequestParams params )
                {
                    request.setup(params);

                    mixin(instance).schedule(params, &this.assignParams,
                        &this.assignScheduledRequest, schedule_ms);
                });
        }


        /***********************************************************************

            Returns:
                scheduler instance

        ***********************************************************************/

        public RequestScheduler scheduler ( )
        {
            return mixin(instance);
        }


        /***********************************************************************

            Assigns a serialized request to the client. The request is passed in
            the form of the serialized data which was stored in the scheduler.

            Params:
                data = serialized request params

        ***********************************************************************/

        private void assignScheduledRequest ( ubyte[] data )
        {
            this.scopeRequestParams(
                ( IRequestParams params )
                {
                    params.deserialize(data);

                    this.assignParams(params);
                });
        }
    }
}
