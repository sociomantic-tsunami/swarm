/*******************************************************************************

    Fiber-suspending request performing plugin.

    The code inside the Extension template (see below) is mixed into the client.

    copyright:      Copyright (c) 2012-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.plugins.ScopeRequests;

import ocean.transition;

/*******************************************************************************

    Fiber-suspending request performing plugin for swarm client. (To be used
    with the ExtensibleXClient class templates.)

*******************************************************************************/

public class ScopeRequestsPlugin
{
    /***************************************************************************

        Code to be mixed into the client.

    ***************************************************************************/

    template Extension ( istring instance )
    {
        /***********************************************************************

            Imports needed by mixin.

        ***********************************************************************/

        import swarm.client.model.IClient;

        import swarm.client.request.notifier.IRequestNotification;

        import ocean.core.MessageFiber;

        debug ( SwarmClient ) import ocean.io.Stdout;


        /***********************************************************************

            Scope class to perform a set of client requests, suspending a fiber
            (specified in the constructor) until all have completed.

        ***********************************************************************/

        public scope class ScopeRequests
        {
            /*******************************************************************

                Token used when suspending / resuming fiber.

            *******************************************************************/

            static private MessageFiber.Token RequestsFinished;


            /*******************************************************************

                Static ctor. Initialises fiber token.

            *******************************************************************/

            static this ( )
            {
                RequestsFinished = MessageFiber.Token("requests_finished");
            }


            /*******************************************************************

                Fiber to suspend when requests need to wait for I/O.

            *******************************************************************/

            private MessageFiber fiber;


            /*******************************************************************

                Flag set to true when suspended.

            *******************************************************************/

            private bool suspended;


            /*******************************************************************

                All public calls must enter and exit inside the running fiber.

            *******************************************************************/

            invariant ( )
            {
                assert (!this.suspended, "fiber is suspended");
            }


            /*******************************************************************

                Count of pending requests.

            *******************************************************************/

            private size_t pending;


            /*******************************************************************

                User notification delegate. Called when a notification occurrs
                for one of the managed requests. All assigned requests must have
                the same notifier delegate (see assign()).

            *******************************************************************/

            private RequestNotification.Callback notifier;


            /*******************************************************************

                Constructor.

                Params:
                    fiber = fiber to suspend when requests need to wait for I/O

            *******************************************************************/

            public this ( MessageFiber fiber )
            {
                this.fiber = fiber;
            }


            /*******************************************************************

                Destructor. Performs any pending requests.

            *******************************************************************/

            ~this ( )
            {
                this.go();
            }


            /*******************************************************************

                Assigns a request to be performed when the go() method is
                called.

                Template params:
                    T = request type (should be one of the structs defined in
                        the client module)

                Params:
                    request = request to assign

            *******************************************************************/

            public void assign ( T ) ( T request )
            {
                if ( pending == 0 )
                {
                    this.notifier = request.notification_dg;
                }
                else
                {
                    assert(this.notifier == request.notification_dg,
                        "Requests assigned via perform() must all have the same notification delegate");
                }

                request.notification_dg = &this.notify;

                this.outer.scopeRequestParams(
                    ( IRequestParams params )
                    {
                        request.setup(params);

                        auto num_requests =
                            this.outer.registry.allNodesRequest(params)
                            ? this.outer.nodes.length : 1;
                        this.pending += num_requests;

                        debug ( SwarmClient ) Stderr.formatln("ScopeReqeusts: "
                            "assigning command {}, {} remaining before resuming fiber",
                            params.command, this.pending);
                    });
                this.outer.assign(request);
            }


            /*******************************************************************

                Performs all pending requests, suspending the fiber until all
                have completed.

                Returns:
                    true if the fiber was suspended, false otherwise (in the
                    case where no requests were pending)

            *******************************************************************/

            public bool go ( )
            {
                bool suspend = this.pending != 0;

                if ( suspend )
                {
                    this.suspended = true;

                    this.fiber.suspend(RequestsFinished, this, fiber.Message(true));
                }

                return suspend;
            }


            /*******************************************************************

                Request notification callback method. The user notifier, if one
                has been set, is called. If the notification indicates that a
                request has finished, the pending counter is decremented.
                If no further requests are pending the fiber is resumed.

                All assigned requests use this as their notifier.

                Params:
                    info = client request notification

            *******************************************************************/

            private void notify ( IRequestNotification info )
            in
            {
                assert (this.pending, "no requests pending when notified");
            }
            body
            {
                try
                {
                    if ( info.type == info.type.Finished )
                    {
                        this.pending--;

                        debug ( SwarmClient ) Stderr.formatln("ScopeReqeusts: "
                            "{} ({}) finished, {} remaining before resuming fiber",
                            info.command_description, info.command, this.pending);
                    }

                    if ( this.notifier )
                    {
                        this.notifier(info);
                    }
                }
                finally if ( !this.pending && this.suspended )
                {
                    this.suspended = false;

                    debug ( SwarmClient ) Stderr.formatln("ScopeReqeusts: "
                        "resuming fiber");

                    this.fiber.resume(RequestsFinished, this);
                }
            }
        }


        /***********************************************************************

            Performs the specified set of requests, suspending the given fiber
            until all requests have completed.

            Template params:
                T = tuple of types of requests to perform (should be the structs
                    defined in the client module)

            Params:
                fiber = fiber to suspend
                requests = tuple of requests to perform

            Returns:
                true if the fiber was suspended, false otherwise (in the case
                where all requests were completed without needing to wait for
                I/O)

        ***********************************************************************/

        public bool perform ( T ... ) ( MessageFiber fiber, T requests )
        {
            static assert(T.length, "Cannot perform nothing");

            scope fiber_requests = new ScopeRequests(fiber);
            foreach ( request; requests )
            {
                fiber_requests.assign(request);
            }
            return fiber_requests.go();
        }
    }
}
