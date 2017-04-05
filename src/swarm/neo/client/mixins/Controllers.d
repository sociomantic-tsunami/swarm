/*******************************************************************************

    Client core mixin template. Provides templates for request control helper
    classes.

    These classes are implemented as a template mixin because they need access
    to the outer class' (i.e. the neo client's) `control` method.

    Copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.client.mixins.Controllers;

template Controllers ( )
{
    /***************************************************************************

        Class template to provide a different API for request controllers.
        Instead of the standard interface, via the `control!()` template method,
        which requires the request id to be specified with each call and returns
        false if the request no longer exists, this class takes the request id
        as a constructor argument (changeable via a method) and throws, when
        used, if the request no longer exists.

        Params:
            ControllerInterface = controller interface of request to be
                controlled

    ***************************************************************************/

    public class Controller ( ControllerInterface )
    {
        import swarm.neo.protocol.Message: RequestId;
        import ocean.core.Enforce;

        /***********************************************************************

            Indicates whether this instance has been bound to a request or not.
            (See bindToRequest().)

        ***********************************************************************/

        private bool initialised;

        /***********************************************************************

            id of request being controlled by this object

        ***********************************************************************/

        private RequestId id_;

        /***********************************************************************

            Constructor. Does not bind this instance to a request id. Use this
            constructor to create an instance to be initialised at some point
            later on, via bindToRequest().

        ***********************************************************************/

        public this ( )
        {
        }

        /***********************************************************************

            Constructor. Binds this instance to the specified request id.

            Params:
                id = id of request to be controlled (the return value of the
                    method which assigned your request)

        ***********************************************************************/

        public this ( RequestId id )
        {
            this.bindToRequest(id);
        }

        /***********************************************************************

            Returns:
                the id of the request being controlled by this object

        ***********************************************************************/

        public RequestId id ( )
        in
        {
            assert(this.initialised);
        }
        body
        {
            return this.id_;
        }

        /***********************************************************************

            Changes the request id being controller by this object. This may be
            useful if you want to construct a single instance of this class and
            reuse it for multiple consecutive requests.

            Params:
                id = id of request to be controlled (the return value of the
                    method which assigned your request)

        ***********************************************************************/

        public void bindToRequest ( RequestId id )
        {
            this.initialised = true;
            this.id_ = id;
        }

        /***********************************************************************

            Gets access to a controller for the request specified in the ctor.
            If the request is still active, the controller is passed to the
            provided delegate for use.

            Params:
                dg = delegate which is called with the controller, if the
                    request is still active

            Throws:
                if the controlled request no longer exists

        ***********************************************************************/

        public void control ( void delegate ( ControllerInterface ) dg )
        in
        {
            assert(this.initialised);
        }
        body
        {
            enforce(this.outer.control(this.id_, dg),
                "Request no longer exists");
        }
    }

    /***************************************************************************

        Class template to provide an `ISuspendable` API for request controllers,
        based on the `Controller` class, above. The request to be controlled
        must implement `suspend()` and `resume()` methods, both expecting no
        arguments.

        Note that, while it implements the standard ISuspendable, this class is
        only a partial match for that interface. The difference lies in the fact
        that suspendable requests only allow a single state-change (i.e. suspend
        or resume) signal to be in flight to the node at any one time. Because
        of this -- and at odds with what ISuspendable normally expects -- a call
        to suspend() or resume() may not immediately take effect. Instead, the
        Suspendable notes that a state-change was requested and carries it out
        when the handlePending() method is called by the user. Thus,
        handlePending() should be called when the user is notified that the
        previous state-change has been completed.

        (In the future, we may adapt the suspendable/throttling code in ocean to
        handle this different case.)

        Params:
            ControllerInterface = controller interface of request to be
                controlled

    ***************************************************************************/

    import ocean.io.model.ISuspendable;

    public class Suspendable ( ControllerInterface ) :
        Controller!(ControllerInterface), ISuspendable
    {
        /***********************************************************************

            Enum of possible pending state-changes.

        ***********************************************************************/

        private enum Pending
        {
            None,
            Suspend,
            Resume
        }

        /***********************************************************************

            Pending state-change.

        ***********************************************************************/

        private Pending pending;

        /***********************************************************************

            Constructor. Does not bind this instance to a request id. Use this
            constructor to create an instance to be initialised at some point
            later on, via bindToRequest().

        ***********************************************************************/

        public this ( )
        {
            super();
        }

        /***********************************************************************

            Constructor. Binds this instance to the specified request id.

            Params:
                id = id of request to be controlled (the return value of the
                    method which assigned your request)

        ***********************************************************************/

        public this ( RequestId id )
        {
            super(id);
        }

        /***********************************************************************

            Requests that further processing be temporarily suspended, until
            resume() is called. Note that it may not be possible to suspend the
            request immediately (if another state-change is already in flight).
            To cover this eventuality, you should always call handlePending()
            when the request notifies you that a state-change has been completed
            (i.e. in the `suspended` and `resumed` cases of your notifier).

            Throws:
                if the Consume request no longer exists

        ***********************************************************************/

        public void suspend ( )
        {
            this.control(
                ( ControllerInterface controller )
                {
                    if ( !controller.suspend() )
                        this.pending = Pending.Suspend;
                }
            );
        }

        /***********************************************************************

            Requests that processing be resumed.  Note that it may not be
            possible to resume the request immediately (if another state-change
            is already in flight). To cover this eventuality, you should always
            call handlePending() when the request notifies you that a
            state-change has been completed (i.e. in the `suspended` and
            `resumed` cases of your notifier).

            Throws:
                if the Consume request no longer exists

        ***********************************************************************/

        public void resume ( )
        {
            this.control(
                ( ControllerInterface controller )
                {
                    if ( !controller.resume() )
                        this.pending = Pending.Resume;
                }
            );
        }

        /***********************************************************************

            Initiates a state-change which was requested while a previous state-
            change was in flight.

            This method *must* be called when (and only when) the request's
            notifier indicates that a previously intitiated state-change (i.e.
            suspend/resume) has been completed. You can simply call it in the
            `suspended` and `resumed` cases of your notifier.

        ***********************************************************************/

        public void handlePending ( )
        {
            switch ( this.pending )
            {
                case Pending.None:
                    break;
                case Pending.Suspend:
                    this.pending = Pending.None;
                    this.suspend();
                    break;
                case Pending.Resume:
                    this.pending = Pending.None;
                    this.resume();
                    break;
                default: assert(false);
            }
            assert(this.pending == Pending.None,
                "handlePending() called when request is not ready");
        }

        /***********************************************************************

            This method of `ISuspendable` cannot currently be implemented and
            thus always throws. To implement this method correctly, this class
            would need to somehow hook into the notifications of the request
            being controlled, in order to receive the suspended/resumed
            notifications to know when the request had actually changed state
            (on the nodes' side).

            Returns:
                true if the process is suspended

            Throws:
                always; unsupported

        ***********************************************************************/

        public bool suspended ( )
        {
            throw new Exception("ISuspendable.suspended() is not currently supported "
                ~ "by " ~ typeof(this).stringof);
        }
    }
}
