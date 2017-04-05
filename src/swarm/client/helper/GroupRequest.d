/*******************************************************************************

    Group request helper class template.

    Manages the finished notifications for the individual requests spawned by
    multi-node commands.

    When the requests to all nodes in the group have finished, the notifier
    callback for the request is called once more with type GroupFinished.

    It is intended that the class template can be derived from, overriding the
    methods oneFinished() and allFinished() as needed to implement special
    behaviour.

    copyright:      Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.helper.GroupRequest;



/*******************************************************************************

    Imports

*******************************************************************************/

import swarm.client.model.IClient;

import swarm.client.request.params.IRequestParams;

import swarm.client.request.notifier.IRequestNotification;

import swarm.client.request.context.RequestContext;

import swarm.Const;



/*******************************************************************************

    Abstract base for group request helper classes.

    The concrete class depends on various template parameters, see below. It is
    convenient to have a non-templated base class

*******************************************************************************/

public abstract class IGroupRequest
{
    /***************************************************************************

        Local type redefinitions.

    ***************************************************************************/

    protected alias .IRequestParams IRequestParams;
    protected alias .RequestContext RequestContext;


    /***************************************************************************

        Alias for a notifier callback

    ***************************************************************************/

    protected alias void delegate ( IRequestNotification ) Callback;


    /***************************************************************************

        Number of nodes that finished the request

    ***************************************************************************/

    protected uint num_finished = 0;


    /***************************************************************************

        Whether any of the nodes had an error. When all requests in the group
        have finished, if this flag is set then the final

    ***************************************************************************/

    protected bool had_error = false;


    /***************************************************************************

        Instance of the client.

        Note: This should be set (with the setClient() method) by the client
        when this instance is assigned / shceduled.

    ***************************************************************************/

    protected IClient client;


    /***************************************************************************

        Original notifier from the user

    ***************************************************************************/

    private Callback user_notifier;


    /***************************************************************************

        Exception passed to notifier delegate when an error occurred while
        processing a group request.

    ***************************************************************************/

    public static class GroupErrorException : Exception
    {
        public this ( )
        {
            super(">= 1 requests in group failed");
        }
    }

    private static GroupErrorException group_error_exception;


    /***************************************************************************

        Static constructor, creates shared exception instance

    ***************************************************************************/

    static this ( )
    {
        group_error_exception = new GroupErrorException;
    }


    /***************************************************************************

        Note: This method should only be called by the client when this instance
        is assigned / scheduled. It is only public as there's no nice way to
        make if accessible *only* from an IClient instance.

        TODO: maybe there is a way?

        ** Do not call this method from application code! **

        Sets up the provided request params class instance from the settings of
        this IGroupRequest instance. The abstract setup_() method is called,
        which returns the notification delegate to be called internally. The
        notification delegate of the provided request params class instance is
        modified to the notifier() member of this class, which handles all
        notifications from the requests in the group.

        Params:
            params = request params instance to write to

    ***************************************************************************/

    public void setup ( IRequestParams params )
    {
        auto notifier = this.setup_(params);
        assert(notifier != &this.notifier, typeof(this).stringof ~
            ".setup: setting notifier to this.notifier will lead to infinite recursion!");

        this.user_notifier = notifier;
        params.notifier = &this.notifier;
    }


    /***************************************************************************

        Sets up the provided request params class instance from the settings of
        this IGroupRequest instance. Also returns the notification delegate to
        be called internally.

        Params:
            params = request params instance to write to

        Returns:
            notification callback to call when a notification is received from
            one of the requests in the group, or when the whole group of
            requests has finished

    ***************************************************************************/

    protected abstract Callback setup_ ( IRequestParams params );


    /***************************************************************************

        Sets the client reference member. Should be called by the client when
        this instance is assigned / scheduled.

        Params:
            client = client instance

        TODO: possibly the client could be passed via the IRequestParams

        TODO: would it be better to call reset() when beginning a group request,
        rather than when it finishes?

    ***************************************************************************/

    public void setClient ( IClient client )
    in
    {
        assert(client !is null,
                typeof(this).stringof ~ ".setClient: client instance is null");
    }
    body
    {
        this.client = client;
    }

    /***************************************************************************

        Called when one request in the group is finished.

        Params:
            info = object containing notification information

        Returns:
            true to indicate that one of the grouped requests should be counted
            as finished

     ***************************************************************************/

    protected bool oneFinished ( IRequestNotification info )
    {
        return true;
    }


    /***************************************************************************

        Called when all requests in the group are finished. May be overridden
        by a subclass.

    ***************************************************************************/

    protected void allFinished ( )
    {
    }


    /***************************************************************************

        Returns:
            the number of requests in the group (defaults to the number of nodes
            in the client's registry).

    ***************************************************************************/

    protected size_t length ( )
    {
        return this.client !is null? this.client.nodes.length : 0;
    }


    /***************************************************************************

        Internal request notifier callback. Calls the oneFinished() and
        allFinished() methods as appropriate.

        Params:
            info = object containing notification information

    ***************************************************************************/

    private void notifier ( IRequestNotification info )
    in
    {
        assert(this.client !is null,
                typeof(this).stringof ~ ".notifier: client instance is null");
    }
    body
    {
        if ( this.user_notifier !is null )
        {
            this.user_notifier(info);
        }

        if ( info.type == info.type.Finished )
        {
            if ( this.oneFinished(info) )
            {
                this.num_finished++;

                this.had_error = !info.succeeded ? true : this.had_error;
            }

            if ( this.num_finished >= this.length )
            {
                this.reset();

                try // user notifier may throw
                {
                    if ( this.user_notifier !is null )
                    {
                        this.sendNotification((IRequestNotification info){
                            info.type = info.type.GroupFinished;
                            info.exception = this.had_error ?
                                group_error_exception : null;

                            this.user_notifier(info);
                        });
                    }
                }
                finally
                {
                    this.allFinished();
                }
            }
        }
    }


    /***************************************************************************

        Provides an instance of a class derived from the abstract
        IRequestNotification for use in the notifier() method, above.

        The deriving class should new an IRequestNotification derived instance
        as scope and pass it to the provided delegate.

        Params:
            notify_dg = delegate to pass IRequestNotification instance to

    ***************************************************************************/

    protected abstract void sendNotification (
        void delegate ( IRequestNotification info ) notify_dg );


    /***************************************************************************

        Resets all internal members. Called when all sub-requests have finished.

    ***************************************************************************/

    private void reset ( )
    {
        this.had_error = false;

        this.num_finished = 0;
    }
}



/*******************************************************************************

    Group request helper class template.

    Template params:
        Request = type of request setup struct to be stored internally. Should
            be one of the structs returned by the request methods of the client.
        RequestParams = type of request params to be passed into the
            assignParams() method of the client. Must be derived from
            IRequestParams (see swarm.client.request.params.IRequestParams).
        RequestNotification = type of request notification, passed to the
            callback in Request. Must be derived from IRequestNotification
            (see swarm.client.request.notifier.IRequestNotification).

*******************************************************************************/

public class IGroupRequestTemplate ( Request, RequestParams : IRequestParams,
    RequestNotification : IRequestNotification ) : IGroupRequest
{
    /***************************************************************************

        Request struct to be managed as a group request

    ***************************************************************************/

    protected Request request;


    /***************************************************************************

        Constructor

        Params:
            request = Request to handle

    ***************************************************************************/

    public this ( Request request )
    {
        this.request = request;
    }


    /***************************************************************************

        Sets up the provided request params class instance from the settings of
        this IGroupRequest instance. Also returns the notification delegate to
        be called internally.

        Params:
            params = request params instance to write to

        Returns:
            notification callback to call when a notification is received from
            one of the requests in the group, or when the whole group of
            requests has finished

    ***************************************************************************/

    override protected Callback setup_ ( IRequestParams params )
    {
        auto params_ = cast(RequestParams)params;
        this.request.setup(params_);
        return this.request.notifier;
    }


    /***************************************************************************

        Provides an instance of the concrete RequestNotification class (derived
        from the abstract IRequestNotification) for use in the notifier() method
        of the super class.

        Params:
            notify_dg = delegate to pass IRequestNotification instance to

    ***************************************************************************/

    override protected void sendNotification (
        void delegate ( IRequestNotification info ) notify_dg )
    {
        scope info = new RequestNotification(request.command,
            request.context);
        notify_dg(info);
    }
}
