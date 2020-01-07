/*******************************************************************************

    Core functionality required by a request on a specific connection, the
    client and node RequestOnConn classes have this in common.

    This class is also the public API for advanced and customised event
    handling for requests. A request may suspend or resume the fiber on its own
    behalf and manipulate the registrations in the message I/O system, but it
    has to comply to a certain protocol of the message I/O system.

    Sending a request message

    - Set `send_payload` to slice the message payload (it will be copied
      automatically if needed).
    - Call `registerForSending()`.
    - The message may or may not be sent before `registerForSending()` returns.
      If `send_payload` is `null` after `registerForSending()` has returned then
      the message was sent, otherwise it is pending. In the latter case call
      `suspendFiber()` to wait until the message was sent.
    - Make sure `send_payload` keeps referencing the request payload until the
      message is sent or you call `unregisterForSending()`.
    - When the message was sent, the fiber is resumed, `suspendFiber()` will
      return `FiberResumeCode.Sent`, and `send_payload` is reset to `null`.
    - If a connection error happens, `suspendFiber()` will throw an exception
      reflecting the error, and the request is unregistered  for sending.
    - While the fiber is suspended a message for this request may arrive; the
      fiber will then be resumed, and `suspendFiber()` will return
      `FiberResumeCode.Received`. You must be able handle this event, even if it
      would be a protocol error. See "Receiving a request message" below how to
      handle it. If this happens, your request will keep being registered for
      sending a message.
    - You can resume the fiber on your own behalf, but unless you call
      `unregisterForSending()` it stays registered for being resumed after
      sending, which can happen at any time while the fiber is suspended.
    - To cancel a pending message, call `unregisterForSending()`. From that
      point the message will not be sent, nor will the fiber be resumed for that
      reason or `send_payload` be reset to `null`.

    Receiving a request message

    Receiving happens asynchronously: Whenever a message for a request arrives,
    `recv_payload` is set to slice the message payload, and the fiber is resumed
    with `FiberResumeCode.Received`. This means a message can arrive while the
    fiber is suspended to wait for sending or any other event, and the waiting
    `suspendFiber()` sent may -- potentially unexpectedly -- return
    `FiberResumeCode.Received`.

    When expecting an incoming message:
    - Call `registerForErrorNotification()` so that the following
      `suspendFiber()` call(s) will let you know if an error happens on the
      connection, by throwing.
    - Call `suspendFiber()` to wait for the message to arrive; it will return
      `FiberResumeCode.Received`. The request is automatically unregistered for
      connection error notification.
    - You can resume the fiber on your own behalf, but unless you call
      `unregisterForErrorNotification()` it stays registered for connection
      error notification, which can happen at any time while the fiber is
      suspended.

    Whenever `suspendFiber()` returns `FiberResumeCode.Received` -- whether you
    are expecting it or not --, acknowledge the reception of the message by
    setting `recv_payload` to `null`, or a verification wil fail. (The reason
    for this is to avoid turning `recv_payload` into a dangling slice when the
    fiber is suspended the next time.)

    Copyright: Copyright (c) 2016-2017 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.neo.connection.RequestOnConnBase;

/******************************************************************************/

abstract class RequestOnConnBase
{
    import Message = swarm.neo.protocol.Message;
    import swarm.neo.protocol.ProtocolError;
    import swarm.neo.connection.YieldedRequestOnConns;
    import Util = swarm.neo.util.Util;

    import ocean.transition;
    import ocean.core.Verify;

    /// Convenience alias for derived classes
    protected alias Message.RequestId RequestId;

    /***************************************************************************

        Codes returned by `suspendFiber()` to indicate that a message has been
        received or sent for this request.

        When `suspendFiber()` returns `FiberResumeCode.Received`, the caller
        must call `discardRecvPayload()` before suspending the fiber again or
        a verifitcation will fail when this request receives the next message.

    ***************************************************************************/

    public enum FiberResumeCode
    {
        Received = -1,
        Sent = -2,
        ResumedYielded = -3
    }

    static assert(FiberResumeCode.min < 0 && FiberResumeCode.max < 0);

    /***************************************************************************

        The payload of a received request message. It is valid until the fiber
        is suspended or terminates.

    ***************************************************************************/

    protected Const!(void)[] recv_payload_;

    /***************************************************************************

        Slice of the payload to send. It is used only until the fiber is resumed
        with `FiberResumeCode.Sent`.

    ***************************************************************************/

    protected Const!(void[])[] send_payload_;

    /***************************************************************************

        Buffer of void[] slices containing the payload to send. Filled by the
        various send*() methods of EventDispatcher.

    ***************************************************************************/

    private Const!(void)[][] send_payload;

    /***************************************************************************

        Suspends the fiber.

        Returns:
            the fiber message code passed to the `resumeFiber()` call that made
            this method call return.

        Throws:
            Exception if an exception was passed when resuming the fiber.

    ***************************************************************************/

    public int suspendFiber ( )
    {
        with (this.fiber.suspend(this.fiber_token_hash.create(), this))
        {
            switch (active)
            {
                case active.num:
                    return num;
                case active.exc:
                    throw exc;
                default:
                    assert(false, this.classinfo.name ~ ".suspendFiber: " ~
                           "Returned message expected to be num or exc");
            }
        }
    }

    /***************************************************************************

        Starts or resumes the fiber; the waiting `suspendFiber()` call will
        return `code`, which must not be any of the reserved `FiberResumeCode`s.

        Params:
            code = the fiber message code the resumed `suspendFiber()` call
                   should return (unless this call starts the fiber)

        In:
            `code` must be at most `int.max`.

    ***************************************************************************/

    public void resumeFiber ( uint code = 0 )
    {
        verify(code <= int.max,
               "fiber resume code expected to be at most int.max");
        this.resumeFiber_(this.fiber.Message(code));
    }

    /***************************************************************************

        Resumes the fiber; the waiting `suspendFiber()` call will throw e.

        Params:
            e = message to be thrown by the waiting suspend() call

    ***************************************************************************/

    public void resumeFiber ( Exception e )
    {
        this.resumeFiber_(this.fiber.Message(e));
    }

    /***************************************************************************

        Tells whether the fiber is running.

        Returns:
            true if the fiber is running, false if it suspended or terminated

    ***************************************************************************/

    public bool is_running ( )
    {
        return this.fiber.state == this.fiber.state.EXEC;
    }

    /***************************************************************************

        The public API for connection request registration and connection
        shutdown.

    ***************************************************************************/

    public class EventDispatcher
    {
        import swarm.neo.AddrPort;
        import swarm.neo.protocol.MessageParser;
        import ocean.core.SmartUnion;
        import ocean.meta.traits.Indirections : hasIndirections;

        alias RequestOnConnBase.FiberResumeCode FiberResumeCode;

        /**********************************************************************/

        invariant ( )
        {
            assert(this.outer.connection !is null,
                   this.classinfo.name ~ ": Currently not connected");
            assert(this.outer.request_id,
                   this.classinfo.name ~ ": Request id is 0");
        }

        /***********************************************************************

            Bitfield enum to specify the events to wait on. Passed to the
            nextEvent() method.

        ***********************************************************************/

        public enum NextEventFlags
        {
            /// No flags.
            None = 0,

            /// Wait to receive a payload for this request over the connection.
            Receive     = 1 << 0,

            /// Wait for an epoll event-loop cycle to occur.
            Yield       = 1 << 1,

            /// Wait for explicit resume with a positive resume code
            Resume = 1 << 2,
        }

        /// Type of a delegate to fill in a payload for sending.
        alias void delegate ( RequestOnConnBase.EventDispatcher.Payload payload )
            FillPayloadDg;

        /***********************************************************************

            Smart union of events which the dispatcher can notify clients of. An
            instance of this union is returned from the dispatcher method which
            suspends a waiting fiber (see nextEvent()), informing the caller of
            the event which has occurred.

        ***********************************************************************/

        public alias SmartUnion!(EventNotificationUnion) EventNotification;

        /***********************************************************************

            Union of events which the dispatcher can notify about.

        ***********************************************************************/

        private union EventNotificationUnion
        {
            /*******************************************************************

                A payload for this request received over the connection.

            *******************************************************************/

            public struct Received
            {
                /// The message payload.
                Const!(void)[] payload;
            }

            /*******************************************************************

                Struct representing the successful sending of a payload over the
                connection.

            *******************************************************************/

            public struct Sent
            {
                // Dummy struct with no data, used purely as a "flag" in the
                // union to indicate the event which occurred. (As each fiber is
                // only allowed to send one thing at a time, there is no need
                // for this struct to have any fields.
            }

            /*******************************************************************

                Struct representing that the fiber was suspended and then
                resumed after an epoll event-loop cycle has occurred.

            *******************************************************************/

            public struct YieldedThenResumed
            {
                // Dummy struct with no data, used purely as a "flag" in the
                // union to indicate the event which occurred.
            }

            /*******************************************************************

                Struct representing that the request-on-conn fiber was resumed
                with a non-negative code. This has no built-in meaning; the
                caller is expected to interpret the code.

            *******************************************************************/

            public struct ResumedWithCode
            {
                /// Code with which the fiber was resumed.
                uint code;
            }

            /// A payload for this request was received over the connection.
            public Received received;

            /// A payload was sent over the connection.
            public Sent sent;

            /// An epoll event-loop cycle has passed.
            public YieldedThenResumed yielded_resumed;

            /// The request-on-conn fiber was resumed with a non-negative code.
            public ResumedWithCode resumed;
        }

        /***********************************************************************

            Incremental payload aggregator class, used by send*() methods.

        ***********************************************************************/

        public scope class Payload
        {
            import ocean.meta.traits.Indirections : hasIndirections;

            /*******************************************************************

                Fixed-size buffer for storing non-lvalues on the stack during
                sending (see addCopy()).

            *******************************************************************/

            private ubyte[256] copied_values;

            /*******************************************************************

                The number of bytes of `copied_values` which are occupied.

            *******************************************************************/

            private size_t copied_values_used;

            /*******************************************************************

                Constructor. Checks that the payload buffer is empty.

            *******************************************************************/

            private this ( )
            {
                verify(this.outer.outer.send_payload.length == 0);
            }

            /*******************************************************************

                Destructor. Clears the payload buffer.

            *******************************************************************/

            ~this ( )
            {
                this.outer.outer.send_payload.length = 0;
                assumeSafeAppend(this.outer.outer.send_payload);
            }

            /*******************************************************************

                Adds a single element to the payload to be sent.

                Params:
                    elem = reference to the element to add

            *******************************************************************/

            public void add ( T ) ( ref T elem )
            {
                static assert(!hasIndirections!(T));
                this.outer.outer.send_payload ~= (cast(Const!(void*))&elem)[0..T.sizeof];
            }

            /*******************************************************************

                Adds a single element to the payload to be sent, copying it into
                this instance's internal buffer.

                Notes:
                1. values passed to this function are stored in a fixed-size
                   buffer owned by this Payload instance. This places a limit on
                   the number of values that can be added to the payload in this
                   way.
                2. this method exists as a convenient interface allowing
                   non-lvalues (e.g. enum members) to be added to the payload.
                   (The alternative is that the user has to manually create a
                   variable -- that stays in scope! -- for each non-lvalue to be
                   sent. This is messy.)

                Params:
                    elem = element to add

            *******************************************************************/

            public void addCopy ( T ) ( T elem )
            {
                static assert(is(T : long));

                verify(this.copied_values_used + T.sizeof
                    <= this.copied_values.length,
                    "Payload copied values buffer insufficient to store requested value");

                auto start = this.copied_values_used;
                this.copied_values_used += T.sizeof;
                auto slice =
                    this.copied_values[start .. this.copied_values_used];
                slice[] = (cast(ubyte*)&elem)[0..T.sizeof];

                this.outer.outer.send_payload ~= slice;
            }

            /*******************************************************************

                Adds a simple 1-dimensional array to the payload to be sent. For
                the user's convenience, the length of the array is copied
                internally, rather than being sliced. (This makes it possible to
                pass array slices that are stored on the stack.)

                Params:
                    array = reference to the array to add

            *******************************************************************/

            public void addArray ( T: Element[], Element ) ( ref T arr )
            {
                static assert(!hasIndirections!(Element));

                this.addCopy(arr.length);
                this.outer.outer.send_payload ~=
                    (cast(Const!(void)*)arr.ptr)[0..arr.length * Element.sizeof];
            }
        }

        /***********************************************************************

            Returns:
                the address of the remote currently connected to.

        ***********************************************************************/

        public AddrPort remote_address ( )
        {
            return this.outer.connection.remote_address;
        }

        /***********************************************************************

            Initiates a connection shutdown from inside the fiber, throwing `e `
            in all other requests that are currently using this connection or
            attempt to use it until the shutdown is complete.

            Params:
                e = the exception reflecting the reason for the shutdown

        ***********************************************************************/

        public void shutdownConnection ( Exception e )
        {
            this.outer.send_payload_ = null;
            this.outer.recv_payload_ = null;
            this.outer.connection.shutdown(e, this.outer.request_id);
        }

        /***********************************************************************

            Initiates a connection shutdown from inside the fiber, throwing an
            exception of type ProtocolError in all other requests that are
            currently using this connection or attempt to use it, until the
            shutdown is complete. The exception instance is then thrown, killing
            the request handler that called this method.

            Params:
                msg = message to set in exception
                file = source filename to set in exception
                line = source line to set in exception

            Throws:
                The ProtocolError that was used to shut down the connection

        ***********************************************************************/

        public void shutdownWithProtocolError ( cstring msg,
            istring file = __FILE__, int line = __LINE__ )
        {
            auto e = this.outer.connection.protocol_error.set(msg, file, line);
            this.shutdownConnection(e);
            throw e;
        }

        /***********************************************************************

            Returns:
                a reusable `ProtocolError` object to be populated and passed to
                `shutdown()`.

        ***********************************************************************/

        public MessageParser message_parser ( )
        {
            return this.outer.connection.message_parser;
        }

        /***********************************************************************

            Returns:
                a reusable `ProtocolError` object to be populated and passed to
                `shutdown()`.

        ***********************************************************************/

        public ProtocolError protocol_error ( )
        {
            return this.outer.connection.protocol_error;
        }

        /***********************************************************************

            Resumes the request-on-conn fiber with the specified code, if it is
            suspended.

            Params:
                code = code to resume request-on-conn fiber with

            Returns:
                true if the fiber was resumed, false if it was already running

        ***********************************************************************/

        public bool resumeFiber ( ubyte code )
        {
            if ( this.outer.is_running )
                return false;

            this.outer.resumeFiber(code);
            return true;
        }

        /***********************************************************************

            Waits for one of the specified events to occur and returns a
            smart-union denoting which occurred.

            There are four possible types of event:
                1. Receiving a payload for this request.
                2. Sending a payload.
                3. The fiber being resumed after it was yielded and an epoll
                   event-loop cycle occurred.
                4. The fiber being resumed with a non-negative code.

            The fiber is usually suspended while waiting for an event to occur.
            The one exception is when sending -- the send may succeed
            immediately, without needing to suspend the fiber.

            The caller indicates which type of event(s) to wait for via the
            arguments, as follows:
                1. Waiting to receive a payload is indicated by setting the
                   NextEventFlags.Receive bit of `flags`.
                2. Waiting to send a payload is indicated by passing a non-null
                   delegate to `fill_payload`.
                3. Yielding the fiber and waiting for it to be resumed is
                   indicated by setting the NextEventFlags.Yield bit of `flags`.
                4. It is not possible to explicitly request or not request that
                   the fiber wait to be resumed with a non-negative code.

            Params:
                flags = flags indicating whether to wait for receiving &/
                    being resumed after yielding
                fill_payload = optional delegate to fill in a payload to send.
                    If this argument is null, sending does not occur

            Returns:
                an EventNotification instance denoting the event which occurred.
                Note that, whatever types of events to wait for are specified by
                the arguments, it is always possible that a `resumed` event
                (type 4, above) may be returned. The caller must take this into
                account.

            Throws:
                Exception on protocol or I/O error.

        ***********************************************************************/

        public EventNotification nextEvent (
            NextEventFlags flags, scope FillPayloadDg fill_payload = null )
        out ( fired_event )
        {
            auto fired_event_non_const = cast(EventNotification)fired_event;
            assert(fired_event_non_const.active !=
                fired_event_non_const.active.none);
        }
        body
        {
            EventNotification fired_event;

            bool sending = fill_payload !is null;
            bool receiving = (flags & NextEventFlags.Receive) > 0;
            bool yielding = (flags & NextEventFlags.Yield) > 0;
            bool explicit_resume = (flags & NextEventFlags.Resume) > 0;

            // Set up sending, if required.
            scope payload = this.new Payload;

            if ( sending )
            {
                fill_payload(payload);
                this.outer.send_payload_ = this.outer.send_payload;

                // registerForSending may fail if called while connection
                // shutdown is in progress
                scope ( failure )
                    this.outer.send_payload_ = null;

                if (!this.outer.connection.registerForSending(
                    this.outer.request_id))
                {
                    verify(false, "nextEvent: already sending");
                }

                // Sending may succeed immediately. send_payload_ is null, in
                // this case.
                if ( !this.outer.send_payload_ )
                {
                    fired_event.sent = EventNotificationUnion.Sent();
                    return fired_event;
                }
            }

            scope ( exit )
            {
                if ( sending )
                    this.outer.connection.unregisterForSending(
                        this.outer.request_id);
            }

            // Set up receiving, if required.
            if ( receiving )
            {
                // registerForErrorNotification may fail if called while
                // connection shutdown is in progress
                scope ( failure )
                    this.outer.recv_payload_ = null;

                if (!this.outer.connection.registerForErrorNotification(
                    this.outer.request_id))
                {
                    verify(false, "nextEvent: already receiving");
                }
            }

            scope ( exit )
            {
                if ( receiving )
                    this.outer.connection.unregisterForErrorNotification(
                        this.outer.request_id);
            }

            // Set up yielding, if required.
            scope yielded_rqonconn = this.outer.new YieldedRequestOnConn;

            if ( yielding )
            {
                if (!this.outer.yielded_rqonconns.add(yielded_rqonconn))
                    verify(false, "nextEvent: already added to the resumer");
            }

            scope ( exit )
            {
                if ( yielding )
                    this.outer.yielded_rqonconns.remove(yielded_rqonconn);
            }

            // Suspend the fiber and wait for the next event to occur.
            int resume_code = this.outer.suspendFiber();
            switch ( resume_code )
            {
                case FiberResumeCode.Sent:
                    if ( sending )
                    {
                        fired_event.sent = EventNotificationUnion.Sent();
                        sending = false; // don't unregister on exit; already done
                    }
                    else
                    {
                        auto e = this.protocol_error.set(
                            "RequestOnConn unexpectedly resumed with Sent");
                        this.shutdownConnection(e);
                        throw e;
                    }
                    break;

                case FiberResumeCode.ResumedYielded:
                    if ( yielding )
                    {
                        fired_event.yielded_resumed =
                            EventNotificationUnion.YieldedThenResumed();
                        yielding = false; // don't unregister on exit; already done
                    }
                    else
                    {
                        auto e = this.protocol_error.set(
                            "RequestOnConn unexpectedly resumed with ResumedYielded");
                        this.shutdownConnection(e);
                        throw e;
                    }
                    break;

                case FiberResumeCode.Received:
                    if ( receiving )
                    {
                        fired_event.received = EventNotificationUnion.Received(
                            this.withdrawRecvPayload());
                        receiving = false; // don't unregister on exit; already done
                    }
                    else
                    {
                        auto e = this.protocol_error.set(
                            "Unexpected incoming message");
                        this.shutdownConnection(e);
                        throw e;
                    }
                    break;

                default:
                    verify(resume_code >= 0, "nextEvent: " ~
                           "Unsupported negative code used to resume " ~
                           "RequestOnConn fiber");

                    if ( !explicit_resume )
                    {
                        auto e = this.protocol_error.set(
                                "Unexpected explicit fiber resume.");
                        this.shutdownConnection(e);
                        throw e;
                    }

                    fired_event.resumed =
                        EventNotificationUnion.ResumedWithCode(resume_code);

                    break;
            }

            return fired_event;
        }

        /***********************************************************************

            Sends a message for this request to the node.

            Do not resume the fiber before this method has returned or thrown.

            Params:
                fill_payload = delegate called to fill the message payload to
                    send

            Throws:
                Exception on protocol or I/O error. If a message is received for
                this request while this method is waiting for sending to
                complete then a protocol error is raised.

        ***********************************************************************/

        public void send ( scope void delegate ( Payload ) fill_payload )
        {
            auto event = this.nextEvent(NextEventFlags.None, fill_payload);
            verify(event.active == event.active.sent);
        }

        /***********************************************************************

            Receives a message for this request from the node. The message
            payload is expected to consist of one value of type `T`. `T` must be
            a value type (that is, it may not contain indirections).

            You can resume the fiber while it is suspended waiting for a message
            to arrive; pass an `on_other_resume_code` callback in this case. If
            you resume the fiber then receiving the message (i.e. waiting for it
            to arrive) will be cancelled.
            If you won't resume the fiber, pass `on_other_resume_code = null`.

            Params:
                on_other_resume_code = called if you resume the fiber before the
                    the next message for this request arrives, or `null` if you
                    won't resume the fiber

            Returns:
                the payload of the received message.

            Throws:
                Exception on protocol or I/O error. If parsing the received
                message payload detects it does not consist of one `T` value
                then a protocol error is raised.

        ***********************************************************************/

        public T receiveValue ( T ) (
            scope void delegate ( int resume_code ) on_other_resume_code = null
        )
        {
            static assert(!hasIndirections!(T), typeof(this).stringof ~
                          ".receiveValue: Type '" ~ T.stringof ~ "' is not " ~
                          "supported because it has indirections");
            T value;

            auto event = this.nextEvent(NextEventFlags.Receive);
            this.outer.connection.message_parser.parseBody!(T)(
                event.received.payload, value);
            return value;
        }

        /***********************************************************************

            Waits until a message for this request is received from the node.

            Do not resume the fiber before this method has returned or thrown.

            Params:
                received = called with the payload of the next message that
                           arrives for this request

            Throws:
                Exception on protocol or I/O error.

        ***********************************************************************/

        public void receive (
            scope void delegate ( const(void)[] payload ) received )
        {
            auto event = this.nextEvent(NextEventFlags.Receive);
            received(event.received.payload);
        }

        /***********************************************************************

            Returns the most recently received payload and resets it to `null`.

            Returns:
                the most recently received payload.

        ***********************************************************************/

        private Const!(void)[] withdrawRecvPayload ( )
        {
            scope (exit) this.outer.recv_payload_ = null;
            return this.outer.recv_payload_;
        }
    }

    /**************************************************************************/

    import swarm.neo.connection.ConnectionBase;
    import swarm.neo.util.FiberTokenHashGenerator;
    import swarm.neo.util.MessageFiber;

    import ocean.core.Enforce;

    /***************************************************************************

        Helper class to register this instance with the `TaskResumer`, used by
        `EventDispatcher.yield()/yieldReceive()`.

    ***************************************************************************/

    private class YieldedRequestOnConn: YieldedRequestOnConns.IYieldedRequestOnConn
    {
        override public void resume ( )
        {
            this.outer.resumeFiber_(fiber.Message(FiberResumeCode.ResumedYielded));
        }
    }

    /***************************************************************************

        The request id.

    ***************************************************************************/

    protected RequestId request_id;

    /***************************************************************************

        The connection to the node.

    ***************************************************************************/

    protected ConnectionBase connection;

    /***************************************************************************

        The fiber to run the request handler in.

    ***************************************************************************/

    protected MessageFiber fiber;

    /***************************************************************************

        Task resumer used by `EventDispatcher.yield()/yieldReceive()`. May be
        null (if so, it is illegal to call the yield*() or periodicYield*()
        methods of EventDispatcher).

    ***************************************************************************/

    protected YieldedRequestOnConns yielded_rqonconns;

    /***************************************************************************

        The fiber token generator.

    ***************************************************************************/

    protected FiberTokenHashGenerator fiber_token_hash;

    /***************************************************************************

        Constructor.

        Params:
            yielded_rqonconns = object which tracks and resumes yielded
                `RequestOnConn`s. May be null (if so, it is illegal to call the
                yield*() or periodicYield*() methods of EventDispatcher).

    ***************************************************************************/

    protected this ( YieldedRequestOnConns yielded_rqonconns )
    {
        this.fiber = new MessageFiber(&this.runHandler, 64 * 1024);
        this.yielded_rqonconns = yielded_rqonconns;
    }

    /***************************************************************************

        Fiber method, calls the request handler.

    ***************************************************************************/

    abstract protected void runHandler ( );

    /***************************************************************************

        Resumes the fiber, passing `msg` to the waiting `suspendFiber()` call.

        Params:
            msg = the fiber message

    ***************************************************************************/

    protected void resumeFiber_ ( fiber.Message msg )
    {
        this.fiber.resume(this.fiber_token_hash.get(), this, msg);
    }

    /***************************************************************************

        Called when ready to send a message for this request.

        Outputs the payload of the request message to the send callback, then
        resumes the fiber.

        Params:
            send = callback to pass the payload to send to

    ***************************************************************************/

    protected void getPayloadForSending ( scope void delegate ( in void[][] payload ) send )
    {
        try
            send(this.send_payload_);
        finally
            this.send_payload_ = null;

        /*
         * If an error was reported before send() returned then the fiber
         * may have terminated.
         */
        if (this.fiber.waiting)
            this.resumeFiber_(fiber.Message(FiberResumeCode.Sent));
    }

    /***************************************************************************

        Called when a message for this request has arrived.

        Stores a slice to the received message payload, then starts or resumes
        the fiber.

        Params:
            payload = the received message payload

    ***************************************************************************/

    protected void setReceivedPayload ( Const!(void)[] payload )
    {
        this.recv_payload_ = payload;
        this.resumeFiber_(fiber.Message(FiberResumeCode.Received));
    }
}
