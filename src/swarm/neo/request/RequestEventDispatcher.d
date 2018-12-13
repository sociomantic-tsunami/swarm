/*******************************************************************************

    Request event dispatcher for use with multi-fiber requests.

    Three types of events are handled:
        1. "Signals" (ubyte codes) sent between fibers.
        2. Messages received over the connection.
        3. Connection readiness to send a payload.
        4. The passing of an epoll event-loop cycle.

    The types of events are handled somewhat differently, as follows:
        1. Only one request handler fiber may register to be notified of each
           type of signal.
        2. Messages reveived over the connection are expected to begin with a
           byte representing the message type. Only one request handler fiber
           may register to be notified of each type of message.
        3. Each request handler fiber may only register once (at a time) for
           notification of connection send readiness. Send readiness
           notifications are handled in order of registration (i.e. fibers will
           be notified of successive send readiness in the order in which they
           registered to receive this notification.)
        4. Each request handler fiber may only register once (at a time) for
           notification of an epoll event-loop cycle ending, but when the
           notification occurs, all fibers registered for this event are
           resumed (in order of registration).

    Copyright: Copyright (c) 2017 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.neo.request.RequestEventDispatcher;

import core.stdc.string;
import ocean.transition;
import ocean.core.SmartUnion;
import ocean.core.Verify;
import swarm.neo.util.VoidBufferAsArrayOf;

/*******************************************************************************

    Smart union of events which can be registered with the dispatcher. An
    instance of the union, registered with the dispatcher, represents a fiber
    awaiting the event specified by the active field. A single fiber may be
    registered for mutliple events, but some event types may only be registered
    for a single fiber (see RequestEventDispatcher.register).

*******************************************************************************/

private alias SmartUnion!(EventRegistrationUnion) EventRegistration;

/*******************************************************************************

    Union of events which can be registered with the dispatcher.

*******************************************************************************/

private union EventRegistrationUnion
{
    /// Waiting to receive a message over the connection.
    Message message;

    /// Waiting to receive a signal from another fiber.
    Signal signal;

    /// Waiting to send a message over the connection.
    Send send;

    /// Waiting for an epoll event-loop cycle to occur.
    Yield yield;
}

/*******************************************************************************

    Struct representing a fiber awaiting a certain message over the connection.
    Each message is required to begin with a single byte representing the
    message type.

*******************************************************************************/

public struct Message
{
    /// The type of the message being awaited.
    ubyte type;
}

/*******************************************************************************

    Struct representing a fiber awaiting a signal with a certain code.

*******************************************************************************/

public struct Signal
{
    /// The signal being awaited.
    ubyte code;
}

/*******************************************************************************

    Struct representing a fiber awaiting the completion of sending a payload
    over the connection.

*******************************************************************************/

public struct Send
{
    import swarm.neo.connection.RequestOnConnBase;

    /// Alias for a delegate type to set the payload of the message to send.
    alias void delegate ( RequestOnConnBase.EventDispatcher.Payload payload )
        GetPayloadDg;

    /// Delegate to set the payload of the message to send.
    GetPayloadDg get_payload;
}

/*******************************************************************************

    Struct representing a fiber awaiting the completion of an epoll event-loop
    cycle.

*******************************************************************************/

public struct Yield
{
    // Dummy struct with no data, used purely as a "flag" in the smart union to
    // indicate the awaited event.
}

/*******************************************************************************

    Smart union of events which the dispatcher can notify clients of. An
    instance of this union is returned from the dispatcher method which
    suspended a waiting fiber (see RequestEventDispatcher.nextEvent), informing
    it of the event which has occurred.

*******************************************************************************/

public alias SmartUnion!(EventNotificationUnion) EventNotification;

/*******************************************************************************

    Union of events which the dispatcher can notify clients of.

*******************************************************************************/

private union EventNotificationUnion
{
    /// A message was received over the connection.
    ReceivedMessage message;

    /// A signal was passed from another fiber.
    Signalled signal;

    /// A message was sent over the connection.
    Sent sent;

    /// An epoll event-loop cycle occurred.
    YieldedThenResumed yielded_resumed;
}

/*******************************************************************************

    A message received over the connection, broken down into its type and
    payload.

*******************************************************************************/

public struct ReceivedMessage
{
    /// The type of the message.
    ubyte type;

    /// The message payload.
    Const!(void)[] payload;
}

/*******************************************************************************

    A signal which occurred.

*******************************************************************************/

public struct Signalled
{
    /// Code of the signal.
    ubyte code;
}

/*******************************************************************************

    Struct representing the successful sending of a payload over the connection.

*******************************************************************************/

public struct Sent
{
    // Dummy struct with no data, used purely as a "flag" in the smart union to
    // indicate the event which occurred. (As each fiber is only allowed to
    // send one thing at a time (see RequestEventDispatcher.register), there is
    // no need to for this struct to have any fields.
}

/*******************************************************************************

    Struct representing the completion of an epoll event-loop cycle.

*******************************************************************************/

public struct YieldedThenResumed
{
    // Dummy struct with no data, used purely as a "flag" in the smart union to
    // indicate the event which occurred.
}

/*******************************************************************************

    Request event dispatcher for use with multi-fiber requests.

    Three types of events are handled:
        1. "Signals" (ubyte codes) sent between fibers.
        2. Messages received over the connection.
        3. Connection readiness to send a payload.

    The types of events are handled somewhat differently, as follows:
        1. Only one request handler fiber may register to be notified of each
           type of signal.
        2. Messages reveived over the connection are expected to begin with a
           byte representing the message type. Only one request handler fiber
           may register to be notified of each type of message.
        3. Each request handler fiber may only register once (at a time) for
           notification of connection send readiness. Send readiness
           notifications are handled in order of registration (i.e. fibers will
           be notified of successive send readiness in the order in which they
           registered to receive this notification.)

    Note that it's absolutely necessary to call initialise method on it before
    doing any work.

*******************************************************************************/

public struct RequestEventDispatcher
{
    import ocean.core.Enforce;
    import Array = ocean.core.Array : moveToEnd, removeShift, contains, copy;
    import swarm.neo.util.MessageFiber;
    import swarm.neo.connection.RequestOnConnBase;

    /// Struct wrapping a waiting fiber along with the event it is awaiting.
    private struct WaitingFiber
    {
        /// Fiber which is waiting.
        MessageFiber fiber;

        /// Event being awaited.
        EventRegistration event;

        /// Is this instance currently enabled? If false, it will be ignored
        /// when dispatching events.
        bool enabled;
    }

    /// The total count of currently enabled events (see WaitingFiber.enabled).
    private uint enabled_events;

    /// Fibers currently awaiting events. Note that the WaitingFiber.enabled
    /// flag means that it's never necessary to actually remove an element from
    /// this array. This is an optimisation, as array remove operations were
    /// found (by profiling) to be taking a significant number of CPU cycles.
    private VoidBufferAsArrayOf!(WaitingFiber) waiting_fibers;

    /// Buffer into which waiting_fibers are copied when performing an iteration
    /// that can modify the contents of waiting_fibers.
    private VoidBufferAsArrayOf!(WaitingFiber) waiting_fibers_to_iterate;

    /// Event which has fired, to be returned by nextEvent(). (This value is set
    /// by notifyWaitingFiber(), just before resuming the waiting fiber.)
    private EventNotification last_event;

    /// Token passed to fiber suspend/resume calls.
    private static MessageFiber.Token token =
        MessageFiber.Token("RequestEventDispatcher");

    /// List of signals which occurred while the request-on-conn fiber was
    /// running. (Signals which occur when the fiber is suspended are passed to
    /// the fiber resume method, waking it up.)
    private VoidBufferAsArrayOf!(ubyte) queued_signals;

    /***************************************************************************

        Initialises the RequestEventDispatcher setting its initial state.

        Params:
            getVoidArray = void array acquirer. This instance will call this
                           delegate multiple times, to acquire the buffers it
                           needs internally. The request's acquired resources
                           must not be relinquished during the lifetime of this
                           instance.

    ***************************************************************************/

    public void initialise ( void[]* delegate() getVoidArray)
    {
        verify((&this).last_event == (&this).last_event.init);

        (&this).waiting_fibers = VoidBufferAsArrayOf!(WaitingFiber)(getVoidArray());
        (&this).waiting_fibers_to_iterate
            = VoidBufferAsArrayOf!(WaitingFiber)(getVoidArray());
        (&this).queued_signals = VoidBufferAsArrayOf!(ubyte)(getVoidArray());
    }

    /***************************************************************************

        Suspends `fiber` until one of the specified events occurs.

        Params:
            T = tuple of types of events
            fiber = fiber to suspend until one of the specified events occurs
            events = tuple of events to await

        Returns:
            struct describing the event which occurred

    ***************************************************************************/

    public EventNotification nextEvent ( T ... ) ( MessageFiber fiber, T events )
    {
        foreach ( event; events )
        {
            EventRegistration register_event;

            static if( is(typeof(event) == Message) )
                register_event.message = event;
            else static if( is(typeof(event) == Signal) )
                register_event.signal = event;
            else static if( is(typeof(event) == Send) )
                register_event.send = event;
            else static if( is(typeof(event) == Yield) )
                register_event.yield = event;
            else
                static assert(false, "Invalid event type");

            (&this).register(fiber, register_event);
        }

        scope ( exit )
        {
            // This unregisters *all* events for this fiber. Since it's illegal
            // for events to be registered for a fiber while it's not suspended,
            // this is safe.
            (&this).unregisterFiber(fiber);

            (&this).last_event = (&this).last_event.init;
            verify((&this).last_event.active == (&this).last_event.active.none);
        }

        fiber.suspend((&this).token);
        // The code which resumes the fiber is expected to set the value of
        // this.last_event immediately before calling resume().
        verify((&this).last_event.active != (&this).last_event.active.none);
        return (&this).last_event;
    }

    /***************************************************************************

        Convenience wrapper around `nextEvent` for sending only.

        Params:
            fiber = fiber to suspend until the specified payload has been sent
            fill_payload = delegate which should fill in the payload to send

    ***************************************************************************/

    public void send ( MessageFiber fiber, scope Send.GetPayloadDg fill_payload )
    {
        auto event = (&this).nextEvent(fiber, Send(fill_payload));
        enforce(event.active == event.active.sent,
            "Unexpected event: waiting only for write success");
    }

    /***************************************************************************

        Convenience wrapper around `nextEvent` for receiving only. 

        Params:
            T = tuple of types of messages
            fiber = fiber to suspend until one of the specified messages is
                received
            messages = tuple of messages to await

        Returns:
            message which was received

    ***************************************************************************/

    public ReceivedMessage receive ( T ... ) ( MessageFiber fiber, T messages )
    {
        foreach ( message; messages )
            static assert(is(typeof(message) == Message));

        auto event = (&this).nextEvent(fiber, messages);
        return event.message;
    }

    /***************************************************************************

        Convenience wrapper around `nextEvent` for yielding only.

        Params:
            fiber = fiber to suspend until the an event-loop cycle has occurred

    ***************************************************************************/

    public void yield ( MessageFiber fiber )
    {
        auto event = (&this).nextEvent(fiber, Yield());
    }

    /***************************************************************************

        Every `yield_after` calls, suspends `fiber` and resumes it on the next
        event-loop cycle. Otherwise does nothing.

        Params:
            fiber = fiber to suspend until the an event-loop cycle has occurred
            call_count = counter incremented each time this method is called
            yield_after = the number of calls after which this method, when
                called again, should yield

    ***************************************************************************/

    public void periodicYield ( MessageFiber fiber, ref uint call_count,
        Const!(uint) yield_after )
    {
        if ( call_count >= yield_after )
        {
            call_count = 0;
            (&this).yield(fiber);
        }
        else
            call_count++;
    }

    /***************************************************************************

        Unregisters all waiting events of `fiber` and kills the fiber.

        Params:
            fiber = fiber to unregister and abort

    ***************************************************************************/

    public void abort ( MessageFiber fiber )
    {
        verify(!fiber.running, "Cannot abort self");

        (&this).unregisterFiber(fiber);

        if ( fiber.finished )
            return;

        verify(fiber.waiting);
        fiber.kill();
    }

    /***************************************************************************

        Triggers a signal with the specified code. Any fiber which is awaiting
        this signal will be resumed in the next eventLoop cycle.

        Params:
            conn = request-on-conn event dispatcher (required in order to
                resume the request-on-conn fiber, if it is currently suspended)
            code = signal code to trigger

    ***************************************************************************/

    public void signal ( RequestOnConnBase.EventDispatcher conn, ubyte code )
    {
        if ( !conn.resumeFiber(code) )
        {
            // Each signal is only allowed to be handled by one registered
            // fiber, so we must only add each signal once to the list -- the
            // waiting fiber doesn't care how *often* the signal has fired.
            // (Otherwise, a signal can be popped from the list, the waiting
            // fiber resumed, then the signal popped again -- now there's no
            // fiber waiting for it.)
            if ( !Array.contains((&this).queued_signals.array(), code) )
                (&this).queued_signals ~= code;
        }
    }

    /***************************************************************************

        Runs the event loop cycle (wait for events, notify waiting fibers) until
        no waiting fibers are registered.

        Note that the event loop can be aborted by aborting each fiber which has
        events registered (see abort()).

        Params:
            conn = request-on-conn event dispatcher to multiplex fiber I/O
                events over

        Throws:
            any exceptions thrown by the request-on-conn

    ***************************************************************************/

    public void eventLoop ( RequestOnConnBase.EventDispatcher conn )
    {
        WaitingFiber writer;

        try while ( (&this).enabled_events )
        {
            writer = writer.init;

            (&this).dispatchQueuedSignals(conn);

            if ( (&this).waitingWriters() )
                writer = (&this).popWaitingWriter();
            else if ( !(&this).enabled_events )
                break;

            (&this).handleNextEvent(conn, writer);
        }
        catch ( Exception e )
        {
            // If the request-on-conn throws, abort all waiting fibers as they
            // can no longer function in a consistent manner.
            MessageFiber.Message msg;
            msg.exc = e;

            // Copy all WaitingFibers into a separate buffer. This is to avoid
            // the array being iterated over being modified by one of the fibers
            // which is resumed from inside the loop.
            (&this).waiting_fibers_to_iterate.length = (&this).waiting_fibers.length;
            (&this).waiting_fibers_to_iterate.array()[] = (&this).waiting_fibers.array()[];

            foreach ( waiting_fiber; (&this).waiting_fibers_to_iterate.array() )
                if ( waiting_fiber.fiber.waiting )
                    waiting_fiber.fiber.resume((&this).token, null, msg);

            // If a writer fiber was popped from the list, abort that too.
            if ( writer.fiber !is null && writer.fiber.waiting )
                writer.fiber.resume((&this).token, null, msg);

            (&this).waiting_fibers.length = 0;
            throw e;
        }
    }

    /***************************************************************************

        Sends the payload requested by the provided writer fiber (if non-null)
        and handles other events that occur in the meantime.

        Params:
            conn = request-on-conn event dispatcher to multiplex fiber I/O
                events over
            writer = optional writer fiber / event to handle

    ***************************************************************************/

    private void handleNextEvent ( RequestOnConnBase.EventDispatcher conn,
        WaitingFiber writer )
    {
        bool sending = writer != writer.init;
        bool sent;
        Const!(void)[] received;

        do
        {
            (&this).dispatchQueuedSignals(conn);

            RequestOnConnBase.EventDispatcher.NextEventFlags flags;
            flags = flags.Receive | (&this).nextEventYieldResumeFlags();

            auto event = conn.nextEvent(flags,
                sending ? writer.event.send.get_payload : null);
            switch ( event.active )
            {
                case event.active.sent:
                    sent = true;
                    EventNotification fired_event;
                    fired_event.sent = Sent();
                    (&this).notifyWaitingFiber(writer.fiber, fired_event);
                    break;

                case event.active.received:
                    (&this).dispatchReceivedPayload(conn, event.received.payload);
                    break;

                case event.active.resumed:
                    (&this).dispatchSignal(conn, event.resumed.code);
                    break;

                case event.active.yielded_resumed:
                    (&this).resumeYieldedFibers(conn);
                    break;

                default:
                    assert(false);
            }
        }
        while ( sending && !sent );
    }

    /***************************************************************************

        Registers `fiber` as awaiting `event`.

        Params:
            fiber = fiber to register as awaiting an event
            event = event which fiber is awaiting

        Throws:
            1. if a message is being awaited and that message type is already
               registered as being awaited (by the same or another fiber) --
               each message type may only be handled by one fiber.
            2. if a signal is being awaited and that code is already registered
               as being awaited (by the same or another fiber) -- each signal
               may only be handled by one fiber.
            3. if sending a payload is being awaited and the fiber is already
               awaiting another payload being sent -- each fiber may only send
               one payload at a time.
            4. if yielding then resuming is being awaited and the fiber is
               already awaiting this event -- each fiber may only register one
               yield event at a time.

    ***************************************************************************/

    private void register ( MessageFiber fiber, EventRegistration event )
    {
        // See if a matching element is already in this.waiting_fibers.
        WaitingFiber* in_list;
        foreach ( ref waiting_fiber; (&this).waiting_fibers.array() )
        {
            if ( waiting_fiber.fiber == fiber && waiting_fiber.event == event )
            {
                verify(in_list is null);
                verify(!waiting_fiber.enabled);
                in_list = &waiting_fiber;
            }

            // Ensure the user isn't trying to do anything crazy.
            if ( waiting_fiber.enabled &&
                waiting_fiber.event.active == event.active )
            {
                with ( event.Active ) switch ( event.active )
                {
                    case message:
                        verify(waiting_fiber.event.message.type
                            != event.message.type,
                            "Only one fiber may handle each message type");
                        break;
                    case signal:
                        verify(waiting_fiber.event.signal.code
                            != event.signal.code,
                            "Only one fiber may handle each signal");
                        break;
                    case send:
                        verify(waiting_fiber.fiber != fiber,
                            "Each fiber may only send one thing at a time");
                        break;
                    case yield:
                        verify(waiting_fiber.fiber != fiber,
                            "Each fiber may only yield once at a time");
                        break;
                    default:
                        assert(false);
                }
            }
        }

        // Add the new fiber/event to the list, if it was not found.
        if ( in_list is null )
        {
            (&this).waiting_fibers ~= WaitingFiber(fiber, event);
            in_list = &(&this).waiting_fibers.array()[$-1];
        }

        // Set the list element to enabled.
        (&this).enable(*in_list);
    }

    /***************************************************************************

        Unregisters `fiber` as awaiting `event`.

        Params:
            fiber = fiber to unregister as awaiting an event
            event = event which fiber is no longer awaiting

    ***************************************************************************/

    private void unregister ( MessageFiber fiber, EventRegistration event )
    {
        foreach ( ref waiting_fiber; (&this).waiting_fibers.array() )
        {
            if ( waiting_fiber.fiber == fiber && waiting_fiber.event == event )
            {
                (&this).disable(waiting_fiber);
                break;
            }
        }
    }

    /***************************************************************************

        Unregisters all events for `fiber`.

        Params:
            fiber = fiber to unregister events for

    ***************************************************************************/

    private void unregisterFiber ( MessageFiber fiber )
    {
        foreach ( ref waiting_fiber; (&this).waiting_fibers.array() )
        {
            if ( waiting_fiber.fiber == fiber )
                (&this).disable(waiting_fiber);
        }
    }

    /***************************************************************************

        Returns:
            true if any registered fibers are awaiting a send

    ***************************************************************************/

    private bool waitingWriters ( )
    {
        foreach ( waiting_fiber; (&this).waiting_fibers.array() )
            if ( waiting_fiber.enabled &&
                waiting_fiber.event.active == waiting_fiber.event.active.send )
                return true;

        return false;
    }

    /***************************************************************************

        Returns:
            flags to pass to EventDispatcher.nextEvent(), with Resume and/or
            Yield bits set, based on the events that registered fibers are
            waiting for.

    ***************************************************************************/

    RequestOnConnBase.EventDispatcher.NextEventFlags nextEventYieldResumeFlags ()
    {
        RequestOnConnBase.EventDispatcher.NextEventFlags flags;

        // All the flags that this method sets, used for short-circuit the
        // array iteration if we set all relevant flags.
        enum all_set_flags = flags.Yield | flags.Resume;

        foreach ( waiting_fiber; (&this).waiting_fibers.array() )
        {
            if ( waiting_fiber.enabled )
            {
                switch (waiting_fiber.event.active)
                {
                    case waiting_fiber.event.active.signal:
                        flags |= flags.Resume;
                        break;
                    case waiting_fiber.event.active.yield:
                        flags |= flags.Yield;
                        break;
                    default:
                        break;
                }

                if (flags == all_set_flags)
                    return flags;
            }
        }

        return flags;
    }

    /***************************************************************************

        Pops the first fiber awaiting a send from the list of waiting fibers.
        Should only be called after waitingWriters() returns true.

        Returns:
            the first fiber awaiting a send from the list of waiting fibers

    ***************************************************************************/

    private WaitingFiber popWaitingWriter ( )
    out ( const_waiting_fiber )
    {
        auto waiting_fiber = cast(WaitingFiber)const_waiting_fiber;
        assert(waiting_fiber.event.active == waiting_fiber.event.active.send);
    }
    body
    {
        verify((&this).waiting_fibers.length > 0);
        verify((&this).enabled_events > 0);

        foreach ( ref waiting_fiber; (&this).waiting_fibers.array() )
            if ( waiting_fiber.enabled &&
                waiting_fiber.event.active == waiting_fiber.event.active.send )
            {
                (&this).disable(waiting_fiber);
                return waiting_fiber;
            }

        assert(false, "popWaitingWriter() should not be called if waitingWriters() is false");
    }

    /***************************************************************************

        Dispatches any signals which occurred while the request-on-conn fiber
        was running. These are queued up in this.queue_signals.

        Params:
            conn = request-on-conn event dispatcher (require by dispatchSignal)

    ***************************************************************************/

    private void dispatchQueuedSignals ( RequestOnConnBase.EventDispatcher conn )
    out
    {
        assert((&this).queued_signals.length == 0);
    }
    body
    {
        while ( (&this).queued_signals.length > 0 )
        {
            auto code = (&this).queued_signals.array()[0];

            // Shift all the elements to the left by one
            void* src = (&this).queued_signals.array().ptr + 1;
            void* dst = (&this).queued_signals.array().ptr;
            size_t num = ubyte.sizeof * ((&this).queued_signals.length - 1);
            memmove(dst, src, num);

            // adjust buffer length
            (&this).queued_signals.length = (&this).queued_signals.length - 1;

            (&this).dispatchSignal(conn, code);
        }
    }

    /***************************************************************************

        Helper function for eventLoop(). Dispatches the specified signal to the
        appropriate waiting fiber.

        Params:
            conn = request-on-conn event dispatcher (used to throw a protocol
                error, if the signal is not handled)
            signal = signal code

        Throws:
            if the signal is not handled by any waiting fiber

    ***************************************************************************/

    private void dispatchSignal ( RequestOnConnBase.EventDispatcher conn,
        int signal )
    {
        if ( signal < 0 ) // Standard send/receive codes
            return;

        verify(signal <= 255);
        ubyte signal_ubyte = cast(ubyte)signal;

        foreach ( waiting_fiber; (&this).waiting_fibers.array() )
        {
            if ( waiting_fiber.enabled &&
                waiting_fiber.event.active == waiting_fiber.event.active.signal
                && waiting_fiber.event.signal.code == signal_ubyte )
            {
                EventNotification fired_event;
                fired_event.signal = Signalled(signal_ubyte);

                (&this).notifyWaitingFiber(waiting_fiber.fiber, fired_event);
                return;
            }
        }

        throw conn.shutdownWithProtocolError("Unhandled signal code");
    }

    /***************************************************************************

        Helper function for eventLoop(). Dispatches the specified message
        payload to the appropriate waiting fiber, via the first byte which
        represents the type of the message.

        Params:
            conn = request-on-conn event dispatcher (used to parse the message
                type from the payload and to throw a protocol error, if the
                message type is not handled)
            payload = received message

        Throws:
            if the message type is not handled by any waiting fiber

    ***************************************************************************/

    private void dispatchReceivedPayload ( RequestOnConnBase.EventDispatcher conn,
        Const!(void)[] payload )
    {
        auto message_type = *conn.message_parser.getValue!(ubyte)(payload);

        foreach ( waiting_fiber; (&this).waiting_fibers.array() )
        {
            if ( waiting_fiber.enabled &&
                waiting_fiber.event.active == waiting_fiber.event.active.message
                && waiting_fiber.event.message.type == message_type )
            {
                EventNotification fired_event;
                fired_event.message = ReceivedMessage(message_type, payload);

                (&this).notifyWaitingFiber(waiting_fiber.fiber, fired_event);
                return;
            }
        }

        throw conn.shutdownWithProtocolError("Unhandled message");
    }

    /***************************************************************************

        Helper function for eventLoop(). When the request-on-conn fiber is
        resumed after being yielded, resumes any fibers which asked to be
        resumed after yielding.

        Params:
            conn = request-on-conn event dispatcher (used to throw a protocol
                error, if no fibers were waiting)

        Throws:
            if no waiting fiber asked to yield

    ***************************************************************************/

    private void resumeYieldedFibers ( RequestOnConnBase.EventDispatcher conn )
    {
        // Copy WaitingFibers which are registered to be woken up after yielding
        // into a separate buffer. This is to avoid the array being iterated
        // over being modified by one of the fibers which is resumed from inside
        // the loop.
        (&this).waiting_fibers_to_iterate.length = 0;

        foreach ( waiting_fiber; (&this).waiting_fibers.array() )
        {
            if ( waiting_fiber.enabled &&
                waiting_fiber.event.active == waiting_fiber.event.active.yield )
            {
                (&this).waiting_fibers_to_iterate ~= waiting_fiber;
            }
        }

        if ( (&this).waiting_fibers_to_iterate.length == 0 )
            throw conn.shutdownWithProtocolError("Unhandled resume after yield");

        foreach ( fiber_to_notify; (&this).waiting_fibers_to_iterate.array() )
        {
            EventNotification fired_event;
            fired_event.yielded_resumed = YieldedThenResumed();

            (&this).notifyWaitingFiber(fiber_to_notify.fiber, fired_event);
        }
    }

    /***************************************************************************

        Sets the specified WaitingFiber instance to enabled and adjusts the
        total enabled count as appropriate.

        Params:
            waiting_fiber = instance to enable

    ***************************************************************************/

    private void enable ( ref WaitingFiber waiting_fiber )
    {
        if ( !waiting_fiber.enabled )
        {
            waiting_fiber.enabled = true;
            (&this).enabled_events++;
        }
    }

    /***************************************************************************

        Sets the specified WaitingFiber instance to disabled and adjusts the
        total enabled count as appropriate.

        Params:
            waiting_fiber = instance to disable

    ***************************************************************************/

    private void disable ( ref WaitingFiber waiting_fiber )
    {
        if ( waiting_fiber.enabled )
        {
            waiting_fiber.enabled = false;
            (&this).enabled_events--;
        }
    }

    /***************************************************************************

        Passes the specified event to the specified suspended fiber via the
        return value of a call to nextEvent() which suspended the fiber. The
        fiber is resumed.

        Params:
            fiber = fiber to resume with the event
            event = the event to pass to the fiber

    ***************************************************************************/

    private void notifyWaitingFiber ( MessageFiber fiber, EventNotification event )
    {
        verify((&this).last_event.active == (&this).last_event.active.none);
        (&this).last_event = event;
        verify((&this).last_event.active != (&this).last_event.active.none);
        fiber.resume((&this).token);
    }
}
