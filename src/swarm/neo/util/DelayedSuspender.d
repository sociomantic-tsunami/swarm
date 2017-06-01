/*******************************************************************************

    Request handler helper to delay suspension of a fiber until a suitable time.

    It is common to have multiple fibers in a request handler, one of which
    wants to suspend another, at some point. However, it is not possible to
    suspend a fiber from the outside; the suspension must be handled from inside
    the fiber to be suspended. This helper mediates this situation by tracking
    pending suspension requests and allowing the fiber to handle them
    (suspending itself) at an appropriate juncture.

    Copyright: Copyright (c) 2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.util.DelayedSuspender;

/// ditto
struct DelayedSuspender
{
    import swarm.neo.util.MessageFiber;

    /// MessageFiber token to ensure matching suspend & resume calls.
    private static MessageFiber.Token token
        = MessageFiber.Token("DelayedSuspender");

    /// The fiber being managed.
    private MessageFiber fiber;

    /// Enum of possible suspension states.
    private enum SuspendState
    {
        /// No suspension is pending.
        None,

        /// A suspension has been requested by requestSuspension().
        Pending,

        /// The fiber has been suspended by suspendIfRequested().
        Suspended
    }

    /// Current suspension state.
    private SuspendState state = SuspendState.None;

    /***************************************************************************

        Requests that the bound fiber be suspended the next time
        suspendIfRequested() is called.

    ***************************************************************************/

    public void requestSuspension ( )
    {
        with ( SuspendState ) switch ( this.state )
        {
            case None:
                this.state = Pending;
                break;
            case Pending:
                // Suspend already requested; do nothing.
                break;
            case Suspended:
                // Already suspended; do nothing.
                break;
            default: assert(false);
        }
    }

    /***************************************************************************

        Resumes the bound fiber, if it has been suspended by a call to
        suspendIfRequested(). (Note that this method does *not* resume the fiber
        if it has been suspended for any other reason.)

    ***************************************************************************/

    public void resumeIfSuspended ( )
    {
        with ( SuspendState ) switch ( this.state )
        {
            case None:
                // Already running; do nothing.
                break;
            case Pending:
                // Already running; cancel suspend request.
                this.state = None;
                break;
            case Suspended:
                this.state = None;
                this.fiber.resume(this.token);
                break;
            default: assert(false);
        }
    }

    /***************************************************************************

        Suspends the bound fiber, if a suspension has been requested.

    ***************************************************************************/

    public void suspendIfRequested ( )
    {
        with ( SuspendState ) switch ( this.state )
        {
            case None:
            case Suspended:
                // No state change requested; do nothing.
                break;
            case Pending:
                this.state = Suspended;
                this.fiber.suspend(this.token);
                break;
            default: assert(false);
        }
    }
}

/*******************************************************************************

    Example of the most common usage scenario with a worker fiber and a control
    fiber. The control fiber suspends and resumes the worker fiber based on
    messages received from outside (presumably over a connection).

*******************************************************************************/

unittest
{
    class Worker
    {
        private MessageFiber fiber;
        DelayedSuspender suspender;

        public this ( )
        {
            this.fiber = new MessageFiber(&this.fiberMethod, 64 * 1024);
            this.suspender = DelayedSuspender(this.fiber);
        }

        // The worker fiber loops, doing some task one item at a time and then
        // suspending, if requested by the controller fiber.
        void fiberMethod ( )
        {
            while ( true )
            {
                // Do some work that takes a while and should not be interrupted
                // ...

                // Pause, if requested from outside
                this.suspender.suspendIfRequested();
            }
        }
    }

    auto worker = new Worker;

    class Controller
    {
        private MessageFiber fiber;

        public this ( )
        {
            this.fiber = new MessageFiber(&this.fiberMethod, 64 * 1024);
        }

        // The controller fiber loops, receiving control messages from the
        // outside and suspending or resuming the worker fiber accordingly.
        void fiberMethod ( )
        {
            while ( true )
            {
                // Receive incoming message
                // ...
                ubyte msg;

                switch ( msg )
                {
                    case 0: // suspend
                        worker.suspender.requestSuspension();
                        break;
                    case 1: // resume
                        worker.suspender.resumeIfSuspended();
                        break;
                    default:
                        assert(false); // unknown message type
                }
            }
        }
    }

    auto controller = new Controller;
}

version ( UnitTest )
{
    import swarm.neo.util.MessageFiber;
}
