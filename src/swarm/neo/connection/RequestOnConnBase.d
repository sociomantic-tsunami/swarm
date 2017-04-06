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
    setting `recv_payload` to `null`, or an assertion wil fail. (The reason for
    this is to avoid turning `recv_payload` into a dangling slice when the fiber
    is suspended the next time.)

    Copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

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

    /// Convenience alias for derived classes
    protected alias Message.RequestId RequestId;

    /***************************************************************************

        Codes returned by `suspendFiber()` to indicate that a message has been
        received or sent for this request.

        When `suspendFiber()` returns `FiberResumeCode.Received`, the caller
        must call `discardRecvPayload()` before suspending the fiber again or
        an assertion will fail when this request receives the next message.

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

    protected void[][] send_payload_;

    /***************************************************************************

        Buffer of void[] slices containing the payload to send. Filled by the
        various send*() methods of EventDispatcher.

    ***************************************************************************/

    private void[][] send_payload;

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
    in
    {
        assert(code <= int.max,
               "fiber resume code expected to be at most int.max");
    }
    body
    {
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
        import swarm.neo.IPAddress;
        import swarm.neo.protocol.MessageParser;
        import ocean.core.Traits: hasIndirections, StripEnum;

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

            Incremental payload aggregator class, used by send*() methods.

        ***********************************************************************/

        public scope class Payload
        {
            import ocean.core.Traits : hasIndirections;

            /*******************************************************************

                Fixed-size buffer for storing non-lvalues on the stack during
                sending (see addConstant()).

            *******************************************************************/

            private ubyte[16] constants;

            /*******************************************************************

                The number of bytes of `constants` which are occupied.

            *******************************************************************/

            private size_t constants_used;

            /*******************************************************************

                Constructor. Checks that the payload buffer is empty.

            *******************************************************************/

            private this ( )
            {
                assert(this.outer.outer.send_payload.length == 0);
            }

            /*******************************************************************

                Destructor. Clears the payload buffer.

            *******************************************************************/

            ~this ( )
            {
                this.outer.outer.send_payload.length = 0;
                enableStomping(this.outer.outer.send_payload);
            }

            /*******************************************************************

                Adds a single element to the payload to be sent.

                Params:
                    elem = reference to the element to add

            *******************************************************************/

            public void add ( T ) ( ref T elem )
            {
                static assert(!hasIndirections!(T));
                this.outer.outer.send_payload ~= (cast(void*)&elem)[0..T.sizeof];
            }

            /*******************************************************************

                Adds a single element to the payload to be sent, copying it into
                this instance's internal constants buffer.

                Notes:
                1. constants passed to this function are stored in a fixed-size
                   buffer owned by this Payload instance. This places a limit on
                   the number of constants that can be added to the payload in
                   this way.
                2. this method exists as a convenient interface allowing
                   non-lvalues (e.g. enum members) to be added to the payload.
                   (The alternative is that the user has to manually create a
                   variable -- that stays in scope! -- for each non-lvalue to be
                   sent. This is messy.)

                Params:
                    elem = element to add

            *******************************************************************/

            public void addConstant ( T ) ( T elem )
            {
                static assert(is(T : long));

                assert(this.constants_used + T.sizeof <= this.constants.length,
                    "Payload constants buffer insufficient to store requested value");

                auto start = this.constants_used;
                this.constants_used += T.sizeof;
                auto slice = this.constants[start .. this.constants_used];
                slice[] = (cast(ubyte*)&elem)[0..T.sizeof];

                this.outer.outer.send_payload ~= slice;
            }

            /*******************************************************************

                Adds a simple 1-dimensional array to the payload to be sent.

                Params:
                    array = reference to the array to add

            *******************************************************************/

            public void addArray ( T ) ( ref T[] arr )
            {
                static assert(!hasIndirections!(T));

                /*
                 * arr is a dynamic array. To slice the data of arr.length, we
                 * use the implementation detail that a dynamic array is in fact
                 * a struct:
                 *
                 * struct Array
                 * {
                 *     size_t length;
                 *     Element* ptr;
                 * }
                 *
                 * Array is of type array, and Array.length.offsetof = 0 so
                 *
                 *     &arr
                 *
                 * is equivalent to
                 *
                 *     &(arr.length)
                 *
                 * Using this we create a slice to the data of arr.length with
                 *
                 *     (cast(void*)(&arr))[0 .. size_t.sizeof]
                 *
                 * The unittest below verifies that this method works. This is a
                 * hack to avoid having to store the array length in a separate
                 * variable.
                 */
                this.outer.outer.send_payload ~=
                    (cast(void*)&arr)[0..size_t.sizeof];
                this.outer.outer.send_payload ~=
                    (cast(void*)arr.ptr)[0..arr.length * T.sizeof];
            }

            /*******************************************************************

                Confirm that the array-length slicing hack used in addArray(),
                above, works.

            *******************************************************************/

            unittest
            {
                void[][] slices;
                mstring arr = "Hello World!".dup;
                slices ~= (cast(void*)&arr)[0..size_t.sizeof];
                slices ~= (cast(void*)arr.ptr)[0..arr.length];
                assert(slices.length == 2);
                assert(slices[0].length == size_t.sizeof);
                assert(*cast(size_t*)(slices[0].ptr) == arr.length);
                assert(slices[1] is arr);
            }
        }

        /***********************************************************************

            Returns:
                the address of the remote currently connected to.

        ***********************************************************************/

        public IPAddress remote_address ( )
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

            Initiates a connection shutdown from inside the fiber, throwing `e `
            in all other requests that are currently using this connection or
            attempt to use it until the shutdown is complete.

            Params:
                e = the exception reflecting the reason for the shutdown

        ***********************************************************************/

        public ProtocolError shutdownWithProtocolError ( cstring msg,
            istring file = __FILE__, int line = __LINE__ )
        {
            auto e = this.outer.connection.protocol_error.set(msg, file, line);
            this.shutdownConnection(e);
            return e;
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

        public void send ( void delegate ( Payload ) fill_payload )
        {
            scope payload = this.new Payload;
            fill_payload(payload);
            this.send(this.outer.send_payload);
        }

        /***********************************************************************

            Sends a message for this request to the node.

            Do not resume the fiber before this method has returned or thrown.

            Params:
                payload = the message payload to send

            Throws:
                Exception on protocol or I/O error. If a message is received for
                this request while this method is waiting for sending to
                complete then a protocol error is raised.

        ***********************************************************************/

        public void send ( void[][] payload ... )
        {
            int resume_code = this.sendAndHandleEvents(payload);
            assert(resume_code <= 0, "send: User unexpectedy resumed the fiber");
        }

        /***********************************************************************

            Sends a message for this request to the node.

            You may resume the fiber while waiting to send.

            Params:
                fill_payload = delegate called to fill the message payload to
                    send

            Returns:
                - 0 if the message was sent without suspending the fiber,
                - FiberResumeCode.Sent if the message was sent while the fiber
                  was suspended,
                - your non-negative fiber resume code if you resumed the fiber
                  before the message was sent.

            Throws:
                Exception on protocol or I/O error. If a message is received for
                this request while this method is waiting for sending to
                complete then a protocol error is raised.

        ***********************************************************************/

        public int sendAndHandleEvents ( void delegate ( Payload ) fill_payload )
        {
            scope payload = this.new Payload;
            fill_payload(payload);
            return this.sendAndHandleEvents(this.outer.send_payload);
        }

        /***********************************************************************

            Sends a message for this request to the node.

            You may resume the fiber while waiting to send.

            Params:
                payload = the message payload to send, must not be empty

            Returns:
                - 0 if the message was sent without suspending the fiber,
                - FiberResumeCode.Sent if the message was sent while the fiber
                  was suspended,
                - your non-negative fiber resume code if you resumed the fiber
                  before the message was sent.

            Throws:
                Exception on protocol or I/O error. If a message is received for
                this request while this method is waiting for sending to
                complete then a protocol error is raised.

        ***********************************************************************/

        public int sendAndHandleEvents ( void[][] payload ... )
        in
        {
            assert(payload.length, "sendAndHandleEvents: no payload to send");
            assert(this.outer.fiber.running,
                   "sendAndHandleEvents: fiber not running");
            assert(!this.outer.recv_payload_,
                   "sendAndHandleEvents: expected null recv_payload");
            assert(!this.outer.send_payload_,
                   "sendAndHandleEvents: expected null send_payload");
        }
        out
        {
            assert(this.outer.fiber.running,
                  "sendAndHandleEvents: returning outside the fiber");
            assert(!this.outer.send_payload_,
                   "sendAndHandleEvents: send_payload was not reset");
        }
        body
        {
            this.outer.send_payload_ = payload;

            scope (failure) // registerForSending may fail if this is called
            {               // while connection shutdown is in progress
                this.outer.send_payload_ = null;
            }

            if (!this.outer.connection.registerForSending(this.outer.request_id))
                assert(false, "sendAndHandleEvents: already sending");

            scope (failure) // if the fiber is resumed with exception and throws
            {
                this.outer.connection.unregisterForSending(this.outer.request_id);
            }

            // The message may have been sent immediately, send_payload_ is null
            // then. Otherwise suspend the fiber to wait for it to be sent, and
            // call the argument delegates if in the mean time a  message comes
            // in or the fiber is resumed for another reason.

            if (!this.outer.send_payload_)
                return FiberResumeCode.Sent;

            int resume_code = this.outer.suspendFiber();
            switch (resume_code)
            {
                case FiberResumeCode.Sent:
                    break;

                case FiberResumeCode.Received:
                    auto e = this.protocol_error.set(
                        "Unexpected incoming message"
                    );
                    this.shutdownConnection(e);
                    throw e;

                default:
                    assert(resume_code >= 0,
                           "sendAndHandleEvents: Connection fiber " ~
                           "resume code expected to be Sent or Received");
                    this.outer.connection.unregisterForSending(
                        this.outer.request_id
                    );
                    this.outer.send_payload_ = null;
            }

            return resume_code;
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
            void delegate ( int resume_code ) on_other_resume_code = null
        )
        {
            static assert(!hasIndirections!(T), typeof(this).stringof ~
                          ".receiveValue: Type '" ~ T.stringof ~ "' is not " ~
                          "supported because it has indirections");
            T value;

            int resume_code = this.receiveAndHandleEvents(
                (in void[] payload)
                {
                    this.outer.connection.message_parser.parseBody!(T)(
                        payload, value
                    );
                }
            );

            if (resume_code >= 0)
            {
                assert(on_other_resume_code !is null,
                       "User unexpectedy resumed the fiber");
                on_other_resume_code(resume_code);
            }

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

        public void receive ( void delegate ( in void[] payload ) received )
        {
            int resume_code = this.receiveAndHandleEvents(received);
            assert(resume_code <= 0, "receive: User unexpectedy resumed the fiber");
        }

        /***********************************************************************

            Waits until a message for this request is received from the node.

            You can resume the fiber while it is suspended waiting for a message
            to arrive. If you resume the fiber then receiving the message (i.e.
            waiting for it to arrive) will be cancelled.

            Params:
                received = called with the payload of the next message that
                           arrives for this request

            Returns:
                - FiberResumeCode.Received (negative) if a message has arrived,
                - your non-negative fiber resume code if you resumed the fiber
                  while waiting for a message to arrive.

            Throws:
                Exception on protocol or I/O error.

        ***********************************************************************/

        public int receiveAndHandleEvents (
            void delegate ( in void[] payload ) received )
        in
        {
            assert(this.outer.fiber.running, "receive: fiber not running");
            assert(!this.outer.recv_payload_,
                   "receive: expected null recv_payload");
            assert(!this.outer.send_payload_,
                   "receive: expected null send_payload");
        }
        out
        {
            assert(this.outer.fiber.running,
                  "receive: returning outside the fiber");
            assert(!this.outer.recv_payload_,
                   "receive: recv_payload was not reset");
        }
        body
        {
            scope (failure) // Can fail in case this is called from shutdown
            {
                this.outer.recv_payload_ = null;
            }

            if (!this.outer.connection.registerForErrorNotification(
                this.outer.request_id
            ))
                assert(false, "receive: already receiving");

            scope (failure) // if the fiber is resumed with exception and throws
            {
                this.outer.connection.unregisterForErrorNotification(
                    this.outer.request_id
                );
            }

            int resume_code = this.outer.suspendFiber();
            switch (resume_code)
            {
                case FiberResumeCode.Received:
                    received(this.withdrawRecvPayload());
                    break;

                default:
                    assert(resume_code >= 0,
                           "receive: Connection fiber " ~
                           "resume code expected to be Received");
                    this.outer.connection.unregisterForErrorNotification(
                        this.outer.request_id
                    );
            }

            return resume_code;
        }

        /***********************************************************************

            Suspends the fiber and resumes it on the next event loop cycle.

            You can resume the fiber while it is suspended.

            Returns:
                - FiberResumeCode.ResumedYielded (negative) if resumed normally,
                  i.e. in the next event loop cycle
                - your non-negative fiber resume code if you resumed the fiber.

            Throws:
                ProtocolError if a message is received for this request while
                this method is waiting.

        ***********************************************************************/

        public int yieldAndHandleEvents ( )
        in
        {
            assert(this.outer.yielded_rqonconns,
                "yieldAndHandleEvents: yielded request-on-conn tracker is null");
            assert(this.outer.fiber.running,
                   "yieldAndHandleEvents: fiber not running");
            assert(!this.outer.recv_payload_,
                   "yieldAndHandleEvents: expected null recv_payload");
            assert(!this.outer.send_payload_,
                   "yieldAndHandleEvents: expected null send_payload");
        }
        out
        {
            assert(this.outer.fiber.running,
                  "yieldAndHandleEvents: returning outside the fiber");
        }
        body
        {
            scope yielded_rqonconn = this.outer.new YieldedRequestOnConn;
            if (!this.outer.yielded_rqonconns.add(yielded_rqonconn))
                assert(false,
                       "yieldAndHandleEvents: already added to the resumer");

            scope (failure)
            {
                // if the fiber is resumed with exception and throws, or if
                // a message arrives so the switch case below throws
                this.outer.yielded_rqonconns.remove(yielded_rqonconn);
            }

            int resume_code = this.outer.suspendFiber();
            switch (resume_code)
            {
                case FiberResumeCode.ResumedYielded:
                    break;

                case FiberResumeCode.Received:
                    auto e = this.protocol_error.set(
                        "Unexpected incoming message"
                    );
                    this.shutdownConnection(e);
                    throw e;

                default:
                    assert(resume_code >= 0,
                           "yieldAndHandleEvents: Connection fiber resume " ~
                           "code expected to be ResumedYielded or Received");
                    this.outer.yielded_rqonconns.remove(yielded_rqonconn);
            }

            return resume_code;
        }

        /***********************************************************************

            Suspends the fiber and resumes it on the next event loop cycle,
            handling an arriving message while suspended.

            You can resume the fiber while it is suspended.

            Params:
                received = if a message arrives while suspended, called with the
                           payload of that message

            Returns:
                - FiberResumeCode.ResumedYielded (negative) if resumed normally,
                  i.e. in the next event loop cycle
                - FiberResumeCode.Received (negative) if a message has arrived,
                - your non-negative fiber resume code if you resumed the fiber
                  while waiting for a message to arrive.

            Throws:
                Exception on protocol or I/O error.

        ***********************************************************************/

        public int yieldReceiveAndHandleEvents (
            void delegate ( in void[] payload ) received
        )
        in
        {
            assert(this.outer.yielded_rqonconns,
                "yieldReceiveAndHandleEvents: yielded request-on-conn tracker is null");
            assert(this.outer.fiber.running,
                   "yieldReceiveAndHandleEvents: fiber not running");
            assert(!this.outer.recv_payload_,
                   "yieldReceiveAndHandleEvents: expected null recv_payload");
            assert(!this.outer.send_payload_,
                   "yieldReceiveAndHandleEvents: expected null send_payload");
        }
        out
        {
            assert(this.outer.fiber.running,
                  "yieldReceiveAndHandleEvents: returning outside the fiber");
            assert(!this.outer.recv_payload_,
                   "yieldReceiveAndHandleEvents: recv_payload was not reset");
        }
        body
        {
            scope yielded_rqonconn = this.outer.new YieldedRequestOnConn;
            if (!this.outer.yielded_rqonconns.add(yielded_rqonconn))
                assert(false, "yieldReceiveAndHandleEvents: " ~
                              "already added to the resumer");

            if (!this.outer.connection.registerForErrorNotification(
                this.outer.request_id
            ))
                assert(false, "yieldReceiveAndHandleEvents: already receiving");

            scope (failure) // if the fiber is resumed with exception and throws
            {
                this.outer.yielded_rqonconns.remove(yielded_rqonconn);
                this.outer.recv_payload_ = null;
                this.outer.connection.unregisterForErrorNotification(
                    this.outer.request_id
                );
            }

            int resume_code = this.outer.suspendFiber();
            switch (resume_code)
            {
                case FiberResumeCode.ResumedYielded:
                    this.outer.connection.unregisterForErrorNotification(
                        this.outer.request_id
                    );
                    break;

                case FiberResumeCode.Received:
                    this.outer.yielded_rqonconns.remove(yielded_rqonconn);
                    received(this.withdrawRecvPayload());
                    break;

                default:
                    assert(resume_code >= 0, "yieldReceiveAndHandleEvents: " ~
                           "Connection fiber resume code expected to be " ~
                           "ResumedYielded or Received");
                    this.outer.yielded_rqonconns.remove(yielded_rqonconn);
                    this.outer.connection.unregisterForErrorNotification(
                        this.outer.request_id
                    );
            }

            return resume_code;
        }

        /***********************************************************************

            Every n calls, suspends the fiber and resumes it on the next event
            loop cycle. Otherwise does nothing.

            You can resume the fiber while it is suspended.

            Params:
                call_count = counter incremented each time this method is called
                yield_after = the number of calls after which this method, when
                    called again, should yield

            Returns:
                - 0 if no yield occurred
                - FiberResumeCode.ResumedYielded (negative) if resumed normally,
                  i.e. in the next event loop cycle
                - your non-negative fiber resume code if you resumed the fiber.

            Throws:
                ProtocolError if a message is received for this request while
                this method is waiting.

        ***********************************************************************/

        public int periodicYieldAndHandleEvents ( ref uint call_count,
            Const!(uint) yield_after )
        {
            if ( call_count >= yield_after )
            {
                call_count = 0;
                return this.yieldAndHandleEvents();
            }
            else
            {
                call_count++;
                return 0;
            }
        }

        /***********************************************************************

            Every n calls, suspends the fiber and resumes it on the next event
            loop cycle, handling an arriving message while suspended. Otherwise
            does nothing.

            You can resume the fiber while it is suspended.

            Params:
                call_count = counter incremented each time this method is called
                yield_after = the number of calls after which this method, when
                    called again, should yield
                received = if a message arrives while suspended, called with the
                    payload of that message

            Returns:
                - 0 if no yield occurred
                - FiberResumeCode.ResumedYielded (negative) if resumed normally,
                  i.e. in the next event loop cycle
                - FiberResumeCode.Received (negative) if a message has arrived,
                - your non-negative fiber resume code if you resumed the fiber
                  while waiting for a message to arrive.

            Throws:
                Exception on protocol or I/O error.

        ***********************************************************************/

        public int periodicYieldReceiveAndHandleEvents ( ref uint call_count,
            Const!(uint) yield_after, void delegate ( in void[] payload ) received )
        {
            if ( call_count >= yield_after )
            {
                call_count = 0;
                return this.yieldReceiveAndHandleEvents(received);
            }
            else
            {
                call_count++;
                return 0;
            }
        }

        /***********************************************************************

            Attempts to send a message for this request while at the same time
            being ready for the reception of a message. If a message arrives
            while waiting to send, calls `received` and cancels sending the
            message.

            Asserts that you do not resume the fiber before this method has
            returned or thrown.

            Params:
                received = called if a message arrives while waiting to send
                fill_payload = delegate called to fill the message payload to
                    send

            Throws:
                Exception on protocol or I/O error.

        ***********************************************************************/

        public void sendReceive ( void delegate ( in void[] payload ) received,
            void delegate ( Payload ) fill_payload )
        {
            scope payload = this.new Payload;
            fill_payload(payload);
            this.sendReceive(received, this.outer.send_payload);
        }

        /***********************************************************************

            Attempts to send a message for this request while at the same time
            being ready for the reception of a message. If a message arrives
            while waiting to send, calls `received` and cancels sending the
            message.

            Asserts that you do not resume the fiber before this method has
            returned or thrown.

            Params:
                received = called if a message arrives while waiting to send
                payload  = the message payload to send, must not be empty

            Throws:
                Exception on protocol or I/O error.

        ***********************************************************************/

        public void sendReceive (
            void delegate ( in void[] payload ) received,
            void[][] payload ...
        )
        in
        {
            assert(payload.length, "sendReceive: no payload to send");
        }
        body
        {
            int resume_code = this.sendReceiveAndHandleEvents(received, payload);
            assert(resume_code <= 0, "sendReceive: User unexpectedy resumed the fiber");
        }

        /***********************************************************************

            Attempts to send a message for this request while at the same time
            being ready for the reception of a message. If a message arrives
            while waiting to send, calls `received` and cancels sending the
            message.

            You may resume the fiber while waiting to send; both sending and
            receiving a message will then be cancelled.

            Params:
                received = called if a message arrives while waiting to send
                fill_payload = delegate called to fill the message payload to
                    send

            Returns:
                - 0 if the message was sent without suspending the fiber,
                - FiberResumeCode.Sent (negative) if the message was sent while
                  the fiber was suspended,
                - FiberResumeCode.Received (negative) if a message was received
                  while the fiber was suspended (so no message was sent),
                - your non-negative fiber resume code if you resumed the fiber
                  (so no message was sent or received).

            Throws:
                Exception on protocol or I/O error.

        ***********************************************************************/

        public int sendReceiveAndHandleEvents (
            void delegate ( in void[] payload ) received,
            void delegate ( Payload ) fill_payload )
        {
            scope payload = this.new Payload;
            fill_payload(payload);
            return this.sendReceiveAndHandleEvents(received,
                this.outer.send_payload);
        }

        /***********************************************************************

            Attempts to send a message for this request while at the same time
            being ready for the reception of a message. If a message arrives
            while waiting to send, calls `received` and cancels sending the
            message.

            You may resume the fiber while waiting to send; both sending and
            receiving a message will then be cancelled.

            Params:
                received = called if a message arrives while waiting to send
                payload = the the message payload to send, must not be empty

            Returns:
                - 0 if the message was sent without suspending the fiber,
                - FiberResumeCode.Sent (negative) if the message was sent while
                  the fiber was suspended,
                - FiberResumeCode.Received (negative) if a message was received
                  while the fiber was suspended (so no message was sent),
                - your non-negative fiber resume code if you resumed the fiber
                  (so no message was sent or received).

            Throws:
                Exception on protocol or I/O error.

        ***********************************************************************/

        public int sendReceiveAndHandleEvents (
            void delegate ( in void[] recv_payload ) received,
            void[][] payload ...
        )
        in
        {
            assert(received !is null,
                  "sendReceiveAndHandleEvents: null received delegate");
            assert(payload.length,
                   "sendReceiveAndHandleEventsT: empty payload");
            assert(this.outer.fiber.running,
                   "sendReceiveAndHandleEvents: called outside the fiber");
            assert(!this.outer.recv_payload_,
                   "sendReceiveAndHandleEvents: null recv_payload expected");
            assert(!this.outer.send_payload_,
                   "sendReceiveAndHandleEvents: null send_payload expected");
        }
        out
        {
            assert(this.outer.fiber.running,
                  "sendReceiveAndHandleEvents: returning outside the fiber");
            assert(!this.outer.recv_payload_,
                   "sendReceiveAndHandleEvents: recv_payload was not reset");
            assert(!this.outer.send_payload_,
                   "sendReceiveAndHandleEvents: send_payload was not reset");
        }
        body
        {
            this.outer.send_payload_ = payload;

            scope (failure) // register for sending may fail if this is called
            {               // from shutdown
                this.outer.send_payload_ = null;
                this.outer.recv_payload_ = null;
            }

            if (!this.outer.connection.registerForSending(this.outer.request_id))
                assert(false, "sendReceiveAndHandleEvents: already sending");

            scope (failure) // if the fiber is resumed with exception and throws
            {
                this.outer.connection.unregisterForSending(
                        this.outer.request_id
                );
                this.outer.connection.unregisterForErrorNotification(
                        this.outer.request_id
                );
            }

            // The message may have been sent immediately, send_payload_ is null
            // then. Otherwise suspend the fiber to wait for it to be sent, and
            // call the argument delegates if in the mean time a  message comes
            // in or the fiber is resumed for another reason.

            if (!this.outer.send_payload_)
                return 0;

            if (!this.outer.connection.registerForErrorNotification(
                this.outer.request_id
            ))
                assert(false, "sendReceiveAndHandleEvents: already receiving");

            int resume_code = this.outer.suspendFiber();
            switch (resume_code)
            {
                case FiberResumeCode.Sent:
                    this.outer.connection.unregisterForErrorNotification(
                        this.outer.request_id
                    );
                    break;

                case FiberResumeCode.Received:
                    this.outer.connection.unregisterForSending(
                        this.outer.request_id
                    );
                    this.outer.send_payload_ = null;
                    received(this.withdrawRecvPayload());
                    break;

                default:
                    assert(resume_code >= 0,
                           "sendAndHandleEvents: Connection fiber " ~
                           "resume code expected to be Sent or Received");
                    this.outer.connection.unregisterForSending(
                        this.outer.request_id
                    );
                    this.outer.send_payload_ = null;
                    this.outer.connection.unregisterForErrorNotification(
                        this.outer.request_id
                    );
            }

            return resume_code;
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

    protected void getPayloadForSending ( void delegate ( void[][] payload ) send )
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
