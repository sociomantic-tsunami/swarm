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

    Copyright: Copyright (c) 2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.request.RequestEventDispatcher;

import ocean.transition;
import ocean.core.SmartUnion;

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

*******************************************************************************/

public struct RequestEventDispatcher
{
    import ocean.core.Enforce;
    import Array = ocean.core.Array : moveToEnd, removeShift, contains;
    import swarm.neo.util.MessageFiber;
    import swarm.neo.connection.RequestOnConnBase;

    /// Struct wrapping a waiting fiber along with the event it is awaiting.
    private struct WaitingFiber
    {
        /// Fiber which is waiting.
        MessageFiber fiber;

        /// Event being awaited.
        EventRegistration event;
    }

    /// Fibers currently awaiting events.
    private WaitingFiber[] waiting_fibers;

    /// Event which has fired, to be returned by nextEvent(). (This value is set
    /// by notifyWaitingFiber(), just before resuming the waiting fiber.)
    private EventNotification last_event;

    /// Token passed to fiber suspend/resume calls.
    private static MessageFiber.Token token =
        MessageFiber.Token("RequestEventDispatcher");

    /// List of signals which occurred while the request-on-conn fiber was
    /// running. (Signals which occur when the fiber is suspended are passed to
    /// the fiber resume method, waking it up.)
    private ubyte[] queued_signals;

    /***************************************************************************

        Resets this instance to its initial state. This method should be called
        when retrieving an instance from a pool or free list.

    ***************************************************************************/

    public void reset ( )
    {
        this.waiting_fibers.length = 0;
        enableStomping(this.waiting_fibers);

        this.queued_signals.length = 0;
        enableStomping(this.queued_signals);

        this.last_event = this.last_event.init;
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
            else
                static assert(false, "Invalid event type");

            this.register(fiber, register_event);
        }

        scope ( exit )
        {
            foreach ( event; events )
            {
                EventRegistration unregister_event;

                static if( is(typeof(event) == Message) )
                    unregister_event.message = event;
                else static if( is(typeof(event) == Signal) )
                    unregister_event.signal = event;
                else static if( is(typeof(event) == Send) )
                    unregister_event.send = event;
                else
                    static assert(false, "Invalid event type");

                this.unregister(fiber, unregister_event);
            }

            this.last_event = this.last_event.init;
            assert(this.last_event.active == this.last_event.active.none);
        }

        fiber.suspend(this.token);
        // The code which resumes the fiber is expected to set the value of
        // this.last_event immediately before calling resume().
        assert(this.last_event.active != this.last_event.active.none);
        return this.last_event;
    }

    /***************************************************************************

        Convenience wrapper around `nextEvent` for sending only.

        Params:
            fiber = fiber to suspend until the specified payload has been sent
            fill_payload = delegate which should fill in the payload to send

    ***************************************************************************/

    public void send ( MessageFiber fiber, Send.GetPayloadDg fill_payload )
    {
        auto event = this.nextEvent(fiber, Send(fill_payload));
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

        auto event = this.nextEvent(fiber, messages);
        enforce(event.active == event.active.message,
            "Unexpected event: waiting only for message receipt");
        return event.message;
    }

    /***************************************************************************

        Unregisters all waiting events of `fiber` and kills the fiber.

        Params:
            fiber = fiber to unregister and abort

    ***************************************************************************/

    public void abort ( MessageFiber fiber )
    in
    {
        assert(!fiber.running, "Cannot abort self");
    }
    body
    {
        auto original_length = this.waiting_fibers.length;
        this.waiting_fibers.length = Array.moveToEnd(this.waiting_fibers,
            WaitingFiber(fiber),
            ( Const!(WaitingFiber) e1, Const!(WaitingFiber) e2 )
            {
                return e1.fiber == e2.fiber;
            }
        );
        enableStomping(this.waiting_fibers);

        if ( fiber.finished )
        {
            assert(this.waiting_fibers.length == original_length,
                "Terminated fiber still registered with request event dispatcher");
            return;
        }

        assert(fiber.waiting);
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
            this.queued_signals ~= code;
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

        try while ( this.waiting_fibers.length )
        {
            writer = writer.init;

            this.dispatchQueuedSignals(conn);

            if ( this.waitingWriters() )
                writer = this.popWaitingWriter();

            this.handleNextEvent(conn, writer);
        }
        catch ( Exception e )
        {
            // If the request-on-conn throws, abort all waiting fibers as they
            // can no longer function in a consistent manner.
            MessageFiber.Message msg;
            msg.exc = e;
            foreach ( waiting_fiber; this.waiting_fibers )
                if ( waiting_fiber.fiber.waiting )
                    waiting_fiber.fiber.resume(this.token, null, msg);

            // If a writer fiber was popped from the list, abort that too.
            if ( writer.fiber !is null && writer.fiber.waiting )
                writer.fiber.resume(this.token, null, msg);

            this.waiting_fibers.length = 0;
            enableStomping(this.waiting_fibers);

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
            this.dispatchQueuedSignals(conn);

            RequestOnConnBase.EventDispatcher.NextEventFlags flags;
            flags = flags.Receive;

            auto event = conn.nextEvent(flags,
                sending ? writer.event.send.get_payload : null);
            switch ( event.active )
            {
                case event.active.sent:
                    sent = true;
                    EventNotification fired_event;
                    fired_event.sent = Sent();
                    this.notifyWaitingFiber(writer.fiber, fired_event);
                    break;

                case event.active.received:
                    this.dispatchReceivedPayload(conn, event.received.payload);
                    break;

                case event.active.resumed:
                    this.dispatchSignal(conn, event.resumed.code);
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

    ***************************************************************************/

    private void register ( MessageFiber fiber, EventRegistration event )
    {
        with ( event.Active ) switch ( event.active )
        {
            case message:
                foreach ( waiting_fiber; this.waiting_fibers )
                    if ( waiting_fiber.event.active == message )
                        enforce(waiting_fiber.event.message.type
                            != event.message.type,
                            "Only one fiber may handle each message type");
                break;
            case signal:
                foreach ( waiting_fiber; this.waiting_fibers )
                    if ( waiting_fiber.event.active == signal )
                        enforce(waiting_fiber.event.signal.code
                            != event.signal.code,
                            "Only one fiber may handle each signal");
                break;
            case send:
                foreach ( waiting_fiber; this.waiting_fibers )
                    if ( waiting_fiber.event.active == send )
                        enforce(waiting_fiber.fiber != fiber,
                            "Each fiber may only send one thing at a time");
                break;
            default:
                assert(false);
        }

        this.waiting_fibers ~= WaitingFiber(fiber, event);
    }

    /***************************************************************************

        Unregisters `fiber` as awaiting `event`.

        Params:
            fiber = fiber to unregister as awaiting an event
            event = event which fiber is no longer awaiting

    ***************************************************************************/

    private void unregister ( MessageFiber fiber, EventRegistration event )
    {
        this.waiting_fibers.length = Array.moveToEnd(this.waiting_fibers,
            WaitingFiber(fiber, event));
        enableStomping(this.waiting_fibers);
    }

    /***************************************************************************

        Returns:
            true if any registered fibers are awaiting a send

    ***************************************************************************/

    private bool waitingWriters ( )
    {
        foreach ( waiting_fiber; this.waiting_fibers )
            if ( waiting_fiber.event.active == waiting_fiber.event.active.send )
                return true;

        return false;
    }

    /***************************************************************************

        Pops the first fiber awaiting a send from the list of waiting fibers.
        Should only be called after waitingWriters() returns true.

        Returns:
            the first fiber awaiting a send from the list of waiting fibers

    ***************************************************************************/

    private WaitingFiber popWaitingWriter ( )
    in
    {
        assert(this.waiting_fibers.length > 0);
    }
    out ( const_waiting_fiber )
    {
        auto waiting_fiber = cast(WaitingFiber)const_waiting_fiber;
        assert(waiting_fiber.event.active == waiting_fiber.event.active.send);
    }
    body
    {
        foreach ( i, waiting_fiber; this.waiting_fibers )
            if ( waiting_fiber.event.active == waiting_fiber.event.active.send )
            {
                WaitingFiber ret = waiting_fiber;
                Array.removeShift(this.waiting_fibers, i);
                return ret;
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
        assert(this.queued_signals.length == 0);
    }
    body
    {
        while ( this.queued_signals.length > 0 )
        {
            auto code = this.queued_signals[0];
            Array.removeShift(this.queued_signals, 0);
            this.dispatchSignal(conn, code);
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

        assert(signal <= 255);
        ubyte signal_ubyte = cast(ubyte)signal;

        foreach ( waiting_fiber; this.waiting_fibers )
        {
            if ( waiting_fiber.event.active == waiting_fiber.event.active.signal
                && waiting_fiber.event.signal.code == signal_ubyte )
            {
                EventNotification fired_event;
                fired_event.signal = Signalled(signal_ubyte);

                this.notifyWaitingFiber(waiting_fiber.fiber, fired_event);
                return;
            }
        }

        conn.shutdownWithProtocolError("Unhandled signal code");
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

        foreach ( waiting_fiber; this.waiting_fibers )
        {
            if ( waiting_fiber.event.active == waiting_fiber.event.active.message
                && waiting_fiber.event.message.type == message_type )
            {
                EventNotification fired_event;
                fired_event.message = ReceivedMessage(message_type, payload);

                this.notifyWaitingFiber(waiting_fiber.fiber, fired_event);
                return;
            }
        }

        conn.shutdownWithProtocolError("Unhandled message");
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
        assert(this.last_event.active == this.last_event.active.none);
        this.last_event = event;
        assert(this.last_event.active != this.last_event.active.none);
        fiber.resume(this.token);
    }
}
