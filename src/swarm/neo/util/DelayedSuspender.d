/*******************************************************************************

    Request handler helper to delay suspension of a fiber until a suitable time.

    It is common to have multiple fibers in a request handler (managed by a
    RequestEventDispatcher), one of which wants to suspend another, at some
    point. However, it is not possible to suspend a fiber from the outside; the
    suspension must be handled from inside the fiber to be suspended. This
    helper mediates this situation by tracking pending suspension requests and
    allowing the fiber to handle them, suspending itself at an appropriate
    juncture.

    Copyright: Copyright (c) 2017 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.neo.util.DelayedSuspender;

/// ditto
struct DelayedSuspender
{
    import swarm.neo.util.MessageFiber;
    import swarm.neo.connection.RequestOnConnBase;
    import swarm.neo.request.RequestEventDispatcher;

    /// The request event dispatcher being used to handle signal dispatch.
    private RequestEventDispatcher* request_event_dispatcher;

    /// The request-on-conn event dispatcher to dispatch signals via.
    private RequestOnConnBase.EventDispatcher conn;

    /// The fiber being managed.
    private MessageFiber fiber;

    /// The signal code to dispatch to resume a waiting fiber.
    private ubyte signal_code;

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

    invariant ( )
    {
        assert((&this).fiber !is null);
        assert((&this).request_event_dispatcher !is null);
        assert((&this).conn !is null);
    }

    /***************************************************************************

        Requests that the bound fiber be suspended the next time
        suspendIfRequested() is called.

    ***************************************************************************/

    public void requestSuspension ( )
    {
        with ( SuspendState ) switch ( (&this).state )
        {
            case None:
                (&this).state = Pending;
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
        with ( SuspendState ) switch ( (&this).state )
        {
            case None:
                // Already running; do nothing.
                break;
            case Pending:
                // Already running; cancel suspend request.
                (&this).state = None;
                break;
            case Suspended:
                (&this).state = None;
                (&this).request_event_dispatcher.signal((&this).conn,
                    (&this).signal_code);
                break;
            default: assert(false);
        }
    }

    /***************************************************************************

        Suspends the bound fiber, if a suspension has been requested.

    ***************************************************************************/

    public void suspendIfRequested ( )
    {
        with ( SuspendState ) switch ( (&this).state )
        {
            case None:
            case Suspended:
                // No state change requested; do nothing.
                break;
            case Pending:
                (&this).state = Suspended;
                (&this).request_event_dispatcher.nextEvent((&this).fiber,
                    Signal((&this).signal_code));
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
    class RequestHandler
    {
        import swarm.neo.util.MessageFiber;
        import swarm.neo.request.RequestEventDispatcher;
        import swarm.neo.connection.RequestOnConnBase;

        /// RequestEventDispatcher instance handling fiber events.
        private RequestEventDispatcher request_event_dispatcher;

        /// Connection that request is operating on.
        private RequestOnConnBase.EventDispatcher conn;

        /// Signal code that suspended fiber waits for.
        static immutable ResumeSuspendedFiber = 23;

        class Worker
        {
            private MessageFiber fiber;
            DelayedSuspender suspender;

            public this ( )
            {
                this.fiber = new MessageFiber(&this.fiberMethod, 64 * 1024);
                this.suspender = DelayedSuspender(
                    &this.outer.request_event_dispatcher, this.outer.conn,
                    this.fiber, ResumeSuspendedFiber);
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

        class Controller
        {
            private MessageFiber fiber;

            private Worker worker;

            public this ( Worker worker )
            {
                this.worker = worker;
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
                            this.worker.suspender.requestSuspension();
                            break;
                        case 1: // resume
                            this.worker.suspender.resumeIfSuspended();
                            break;
                        default:
                            assert(false); // unknown message type
                    }
                }
            }
        }

        this ( RequestOnConnBase.EventDispatcher conn )
        {
            this.conn = conn;
            scope worker = new Worker;
            scope controller = new Controller(worker);
        }
    }
}
