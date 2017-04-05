/*******************************************************************************

    Full-duplex client connection base class. Contains the send and receive
    loops, message dispatching and epoll registration logic and is the select
    client registered with epoll. Subclasses need to implement the connection
    setup, authentication and request dispatching logic.

    Copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.connection.ConnectionBase;

/******************************************************************************/

import ocean.io.select.client.model.ISelectClient;

/******************************************************************************/

abstract class ConnectionBase: ISelectClient
{
    import swarm.neo.IPAddress;

    import swarm.neo.util.TreeQueue;

    import Message = swarm.neo.protocol.Message;
    import swarm.neo.protocol.socket.MessageReceiver;
    import swarm.neo.protocol.socket.MessageSender;
    import swarm.neo.protocol.MessageParser;
    import swarm.neo.protocol.ProtocolError;

    import swarm.neo.util.FiberTokenHashGenerator;
    import swarm.neo.util.MessageFiber;

    import ocean.core.SmartUnion;

    import ocean.io.select.EpollSelectDispatcher;
    import ocean.io.select.protocol.generic.ErrnoIOException;

    import ocean.sys.socket.AddressIPSocket;

    import swarm.neo.util.TreeMap;
    import swarm.neo.protocol.socket.IOStats;

    import ocean.transition;

    debug ( SwarmConn ) import ocean.io.Stdout;


    /// Convenience aliases for derived class
    protected alias Message.RequestId RequestId;
    /// Ditto
    protected alias Message.MessageType MessageType;

    /***************************************************************************

        Stack size of sender/receiver fibers

    ***************************************************************************/

    private const FIBER_STACK_SIZE = 64 * 1024;

    /***************************************************************************

        Fiber which handles sending messages with integrated queue of requests
        which are registered for sending.

        Note that the send loop fiber is used during connection establishment
        and is responsible for starting the receive loop fiber, once the
        connection has been initialised.

        Note that "MessageFiber" refers to the ability of passing an object when
        suspending or resuming the fiber, it has nothing to do with the
        node/client message protocol.

    ***************************************************************************/

    private class SendLoop : MessageFiber
    {
        /***********************************************************************

            Token used when suspending/resuming the fiber.

        ***********************************************************************/

        public FiberTokenHashGenerator fiber_token;

        /***********************************************************************

            Used by registerForSending(). The send fiber is currently waiting
            for:
                false: ... socket output to complete,
                true:  ... an element to be pushed in the request_sender_queue.

        ***********************************************************************/

        public bool idle;

        /***********************************************************************

            Flag that is true while the sending loop has been started.

        ***********************************************************************/

        public bool loop_started;

        /***********************************************************************

            The queue of ids of requests waiting to send a message.

        ***********************************************************************/

        private TreeQueue!(RequestId) queue;

        /***********************************************************************

            Constructor.

        ***********************************************************************/

        public this ( )
        {
            super(&this.fiberMethod, FIBER_STACK_SIZE);
        }

        /***********************************************************************

            Pushes `id` in the queue of ids of requests that are waiting to send
            a message, if it is not already in the queue.

            If the id is pushed to the queue and the sending fiber is idle, it
            is resumed to send the newly pushed message.

            Params:
                id = request id

            Returns:
                true if pushed or false if `id` was already in the queue.

        ***********************************************************************/

        public bool registerForSending ( RequestId id )
        {
            if (this.queue.push(id, !this.idle))
            {
                if ( this.idle )
                {
                    this.resume(this.fiber_token.get(), this.outer);
                }
                return true;
            }
            else
            {
                return false;
            }
        }

        /***********************************************************************

            Removes `id` from the queue of ids of requests that are waiting to
            send a message, if it is in the queue.

            Params:
                id = the request id to remove from the queue

            Returns:
                true if `id` was removed from the queue or false if not found.

        ***********************************************************************/

        public bool unregisterForSending ( RequestId id )
        {
            return this.queue.remove(id);
        }

        /***********************************************************************

            Iterates over the currently queued request ids. Unregisters the
            current request id, then calls `dg` with it on each iteration cycle.
            `dg` should return 0 to continue or non-zero to stop the iteration.

            Params:
                dg = `opApply` style iteration delegate

            Returns:
                0 if all request ids were removed because `dg` always returned 0
                or the return value of `dg` if it returned non-zero to stop the
                iteration. (This complies to an `opApply()` return value).

        ***********************************************************************/

        public int unregisterAll ( int delegate ( ref RequestId id ) dg )
        {
            return this.queue.opApply(dg);
        }

        /***********************************************************************

            Suspends the sending fiber to wait for:
              - a record to be registered for sending (if `this.idle` is true) or
              - socket output to complete (if `this.idle` is false) or
              - a connection shutdown request (resumed with an exception fiber
                message).

            Returns:
                the socket I/O event that caused the fiber to be resumed, if
                waiting for socket output to complete.

            Throws:
                Exception if a connection shutdown is requested.

        ***********************************************************************/

        public Event suspend ( )
        {
            auto msg = super.suspend(this.fiber_token.create(this.idle), this.outer);

            switch (msg.active)
            {
                case msg.active.num:
                    return cast(Event)msg.num;
                case msg.active.exc:
                    throw msg.exc;
                default:
                    assert(false);
            }
        }

        /// D2 requires explicit addition of base class methods into overload set
        alias MessageFiber.suspend suspend;

        /***********************************************************************

            Send fiber method. Initialises the connection (according to the
            abstract method `connect()`, in the outer class). Once the
            connection is initialised, starts the receive fiber, performs the
            sending loop, and shuts the connection down before it returns.

        ***********************************************************************/

        private void fiberMethod ( )
        {
            debug ( SwarmConn )
            {
                Stdout.formatln("SendLoop.fiberMethod() {}", this.outer.remote_address.port);
                scope ( exit ) Stdout.formatln("SendLoop.fiberMethod() exit");
            }

            try while (this.outer.connect())
            {
                debug ( SwarmConn )
                    Stdout.formatln("SendLoop.fiberMethod() connected");

                try
                {
                    // Start the receive fiber, it will suspend itself immediately.
                    this.outer.recv_loop.start();

                    // Run the sending loop. It only exits by throwing.
                    this.loop();
                }
                catch (send_loop.KilledException e)
                {
                    debug ( SwarmConn )
                        Stdout.formatln("SendLoop.fiberMethod(): Killed @{}:{}", e.file, e.line);

                    throw e;
                }
                catch (send_loop.ResumeException e)
                {
                    debug ( SwarmConn )
                        Stdout.formatln("SendLoop.fiberMethod(): ResumeException! @{}:{}", e.file, e.line);

                    // should never happen: TODO log
                    throw e;
                }
                catch (Exception e)
                {
                    debug ( SwarmConn )
                        Stdout.formatln("SendLoop.fiberMethod() caught \"{}\" @{}:{}", getMsg(e), e.file, e.line);

                    this.outer.shutdownImpl(e);
                }
            }
            // Exceptions thrown by this.outer.connect() indicate that the
            // connection could not be established (can include protocol or
            // authentication errors). We simply exit the fiber method, in this
            // case.
            catch ( Exception e )
            {
                debug ( SwarmConn )
                    Stdout.formatln("SendLoop.fiberMethod() caught \"{}\" @{}:{} while connecting",
                        getMsg(e), e.file, e.line);

                this.outer.shutdownImpl(e);
            }
        }

        /***********************************************************************

            Fiber method; performs the sending loop. This is an infinite loop
            which exits only by throwing if a connection shutdown was requested.

            Out:
                This method doesn't return normally, it only throws.

        ***********************************************************************/

        private void loop ( )
        out
        {
            assert(false);
        }
        body
        {
            this.loop_started = true;
            scope (exit)
            {
                this.loop_started = false;
                this.idle = false;
            }

            while (true)
            {
                // Send payloads of requests which are ready to send
                foreach (id; this.queue)
                    this.sendRequestPayload(id);

                /*
                 * Register the socket for input only, and suspend the fiber
                 * to wait until registerForSending() is called.
                 */
                this.outer.registerEpoll(false);
                this.idle = true;
                this.suspend();
                this.idle = false;
            }
        }

        /***********************************************************************

            Handles the payload of the specified request which has registered as
            wanting to send something.

            Params:
                id = id of the request to handle

            Out:
                This method doesn't return normally, it only throws.

        ***********************************************************************/

        private void sendRequestPayload ( RequestId id )
        {
            bool finish_sending = false;

            this.outer.getPayloadForSending(
                id,
                ( void[][] payload )
                {
                    finish_sending = this.outer.sender.assign(
                        MessageType.Request, payload,
                        (cast(void*)(&id))[0 .. id.sizeof]
                    );
                }
            );

            if (finish_sending)
            {
                // Register the socket for both input and output
                this.outer.registerEpoll(true);
                this.outer.sender.finishSending(this.suspend());
            }
        }
    }

    protected MessageParser parser;

    /***************************************************************************

        Fiber which handles receiving messages with integrated set of requests
        which are registered for receiving.

        Note that "MessageFiber" refers to the ability of passing an object when
        suspending or resuming the fiber, it has nothing to do with the
        node/client message protocol.

    ***************************************************************************/

    private class ReceiveLoop : MessageFiber
    {
        import ocean.util.container.ebtree.c.eb64tree: eb64_node;

        /***********************************************************************

            Token used when suspending/resuming the fiber.

        ***********************************************************************/

        public FiberTokenHashGenerator fiber_token;

        /***********************************************************************

            Flag that is true while the receive loop has been started.

        ***********************************************************************/

        public bool loop_started;

        /***********************************************************************

            Flag that is true when the socket has been shut down by
            outer.shutdownImpl(). When true, the message receiving/parsing loop
            in fiberMethod() is broken out of, ending the receive fiber.

        ***********************************************************************/

        public bool connection_closed;

        /***********************************************************************

            The set of ids of requests waiting for a message to arrive.

        ***********************************************************************/

        private TreeMap!() set;

        /***********************************************************************

            Constructor.

        ***********************************************************************/

        public this ( )
        {
            super(&this.fiberMethod, FIBER_STACK_SIZE);
        }

        /***********************************************************************

            Registers a request as waiting to read from the connection.

            Params:
                id = request id

            Returns:
                true if added or false if already registered.

        ***********************************************************************/

        public bool registerForReceiving ( RequestId id )
        {
            bool added;
            this.set.put(id, added);
            return added;
        }

        /***********************************************************************

            Unregisters a request as waiting to read from the connection.

            Params:
                id = request id

            Returns:
                true if removed or false if not found.

        ***********************************************************************/

        public bool unregisterForReceiving ( RequestId id )
        {
            if (auto ebnode = id in this.set)
            {
                this.set.remove(*ebnode);
                return true;
            }
            else
            {
                return false;
            }
        }

        /***********************************************************************

            Iterates over the currently registered requests. Unregisters the
            current request, then calls `dg` with it on each iteration cycle.
            `dg` should return 0 to continue or non-zero to stop the iteration.

            Params:
                dg = `opApply` style iteration delegate

            Returns:
                0 if all request ids were removed because `dg` always returned 0
                or the return value of `dg` if it returned non-zero to stop the
                iteration. (This complies to an `opApply()` return value).

        ***********************************************************************/

        public int unregisterAll ( int delegate ( ref RequestId id ) dg )
        {
            return this.set.opApply(
                (ref eb64_node ebnode)
                {
                    auto request_id = ebnode.key;
                    this.set.remove(ebnode); // Deallocates ebnode!
                    return dg(request_id);
                }
            );
        }

        /***********************************************************************

            Fiber method; performs the receiving loop until an exception happens
            or the connection is closed (by outer.shutdownImpl(), which sets
            this.connection_closed to true).

        ***********************************************************************/

        private void fiberMethod ( )
        in
        {
            assert(!this.outer.current_exception);
        }
        body
        {
            debug ( SwarmConn )
            {
                Stdout.formatln("ReceiveLoop.fiberMethod()");
                scope ( exit ) Stdout.formatln("ReceiveLoop.fiberMethod() exit");
            }

            try
            {
                this.loop_started = true;
                this.connection_closed = false;
                scope (exit) this.loop_started = false;

                while (!this.connection_closed)
                {
                    this.outer.receiver.receive(
                        cast(Event)this.suspend(this.fiber_token.create(true), this.outer).num,
                        &this.receivedMessage
                    );
                }
            }
            catch (KilledException e)
            {
                // Can be caused by doShutdown(), just return.
            }
            catch (ResumeException e)
            {
                // Should never happen: TODO log, then return.
            }
            catch (Exception e)
            {
                // An exception occurred while receiving or parsing messages.
                // (Most likely an I/O or protocol error.) Shut down the
                // connection.
                this.outer.shutdown(e);
            }
        }

        /***********************************************************************

            Handles a received message.

            Params:
                type = type of message received
                msg_body = message payload

        ***********************************************************************/

        private void receivedMessage ( MessageType type, Const!(void)[] msg_body )
        {
            // A previously parsed message decided to shutdown the connection.
            // Don't parse any subsequent pending messages.
            if ( this.connection_closed )
                return;

            auto request_id =
                *this.outer.parser.getValue!(RequestId)(msg_body);
            this.unregisterForReceiving(request_id);

            switch (type)
            {
                case type.Request:
                    // msg_body is now the request payload
                    this.outer.setReceivedPayload(request_id, msg_body);
                    break;

                default: // TODO: throw
            }
        }
    }

    /***************************************************************************

        Message receiver & sender.

    ***************************************************************************/

    protected MessageReceiver receiver;
    protected MessageSender   sender;

    /***************************************************************************

        Sending and receiving loops.

    ***************************************************************************/

    protected ReceiveLoop recv_loop;
    protected SendLoop send_loop;

    /***************************************************************************

        The node/client connection socket.

    ***************************************************************************/

    protected AddressIPSocket!() socket;

    /***************************************************************************

        The epoll select dispatcher to register the socket.

    ***************************************************************************/

    protected EpollSelectDispatcher epoll;

    /***************************************************************************

        The epoll events we are currently waiting for.

    ***************************************************************************/

    protected Event events_;

    /***************************************************************************

        The current exception while error handling.

    ***************************************************************************/

    protected ProtocolError protocol_error_;

    /***************************************************************************

        The current exception while error handling.

    ***************************************************************************/

    protected Exception current_exception = null;

    /***************************************************************************

        Constructor.

        At this point the socket does not have to contain a valid file
        descriptor.

        Params:
            socket       = node/client connection socket
            epoll        = epoll select dispatcher for registering the socket

    ***************************************************************************/

    protected this ( AddressIPSocket!() socket, EpollSelectDispatcher epoll )
    {
        this.socket               = socket;
        this.epoll                = epoll;
        this.protocol_error_      = new ProtocolError;
        this.parser.e             = this.protocol_error_;
        this.receiver             = new MessageReceiver(this.socket, this.protocol_error_);
        this.sender               = new MessageSender(this.socket);
        this.send_loop            = new SendLoop;
        this.recv_loop            = new ReceiveLoop;
    }

    /***************************************************************************

        Returns:
            the address of the remote currently connected to or IPAddress.init
            (zero address & port) if currently not connected.

    ***************************************************************************/

    public IPAddress remote_address ( )
    {
        IPAddress client_address;
        return *client_address.set(this.socket.in_addr);
    }

    /***************************************************************************

        Obtains statistics of the time outgoing messages have spent in the
        queue. The timing statistics include only the messages that had to wait
        because the send fiber was busy when `registerForSending` was called.
        Messages that were processed right away are counted as "notime", see the
        `TimeHistogram` documentation for details.

        Params:
            reset = reset the internal counters upon returning

        Returns:
            statistics of the time outgoing messages have spent in the queue.

    ***************************************************************************/

    public TreeQueueStats getSendQueueStats ( bool reset = false )
    {
        scope (exit)
            if (reset)
                with (this.send_loop.queue)
                    stats = stats.init;

        return this.send_loop.queue.stats;
    }

    /***************************************************************************

        Obtains message and socket I/O statistics for the sender or receiver, as
        specified by the `output` argument.

        Params:
            output = false: return/reset receiver statistics;
                     true: return/reset sender statistics
            reset  = if true, reset the internal counters upon returning

        Returns:
            message and socket I/O statistics.

    ***************************************************************************/

    public IOStats getIOStats ( bool output, bool reset = false )
    {
        IOStats* stats = output? &this.sender.io_stats : &this.receiver.io_stats;
        scope (exit)
            if (reset)
                *stats = (*stats).init;

        return *stats;
    }

    /***************************************************************************

        Starts the engine:
            - Initialises the connection including authentication,
            - registers the socket for reading,
            - starts the send and receive fiber,
            - sends the messages in the queue.

        Returns:
            the connection status after the start was initiated.

        Throws:
            Exception if a shutdown is currently in process. The thrown
            exception reflects the reason for the shutdown (I/O or protocol
            error, for example).

    ***************************************************************************/

    public void start ( )
    {
        if (this.current_exception)
            throw this.current_exception;

        this.send_loop.start();
    }

    /***************************************************************************

        Pushes `id` in the queue of ids of requests that are waiting to send a
        message, if it is not already in the queue.

        Params:
            id = request id

        Returns:
            true if pushed or false if `id` was already in the queue.

        Throws:
            Exception if a shutdown is currently in process. The thrown
            exception reflects the reason for the shutdown (I/O or protocol
            error, for example).

    ***************************************************************************/

    public bool registerForSending ( RequestId id )
    {
        if (this.current_exception)
            throw this.current_exception;

        return this.send_loop.registerForSending(id);
    }

    /***************************************************************************

        Removes `id` from the queue of ids of requests that are waiting to send
        a message, if it is in the queue.

        Params:
            id = the request id to remove from the queue

        Returns:
            true if `id` was removed from the queue or false if not found.

    ***************************************************************************/

    public bool unregisterForSending ( RequestId id )
    {
        return this.send_loop.unregisterForSending(id);
    }

    /***************************************************************************

        Registers a request to be notified if an I/O error occurs on this
        connection.
        Requests waiting for an incoming message should be registered using this
        method.

        Params:
            id = request id

        Returns:
            true if added or false if already registered.

        Throws:
            Exception if a shutdown is currently in process. The thrown
            exception reflects the reason for the shutdown (I/O or protocol
            error, for example).

    ***************************************************************************/

    public bool registerForErrorNotification ( RequestId id )
    {
        if (this.current_exception)
            throw this.current_exception;

        return this.recv_loop.registerForReceiving(id);
    }

    /***************************************************************************

        Unregisters a request from being notified if an I/O error occurs on this
        connection. Note that requests are unregistered automatically when the
        request message payload has been handed over to them.

        Params:
            id = request id

        Returns:
            true if removed or false if not found.

    ***************************************************************************/

    public bool unregisterForErrorNotification ( RequestId id )
    {
        return this.recv_loop.unregisterForReceiving(id);
    }

    /***************************************************************************

        Called from the send fiber before the send/receive loops are started.
        Should perform any required initialisation of the socket, including
        performing any initial authentication or handshake.

        Returns:
            true to proceed with the send/receive loops, false to exit

        Throws:
            if a protocol error occurs during connection auth/handshake

    ***************************************************************************/

    abstract protected bool connect ( );

    /***************************************************************************

        Shuts the engine down:
          - Closes the socket connection.
          - Notifies all request handlers that are waiting to send and/or
            receive a message  (except for `request_id`).

        If calling this method from a request handler, pass the request id so
        that this request handler is not notified to avoid attempting to resume
        its fiber (which is running because it called this method).

        While the connection shutdown is in progress, that is, while the
        registered requests are being notified, `start()`,
        `registerForSending()` and registerForErrorNotification() throw `e` and
        do nothing else. This is for robustness and simpler code in the error
        notification methods of the request handlers, should they indirectly try
        to call any of these.

        Do not call this method from `getPayloadForSending()`.

        This method should not throw.

        Params:
            request_id = the id of the request whose handler calls this method
                         and should not receive a shutdown notification or 0 if 
                         not calling from a request handler
            e          = the exception reflecting the error

        In:
            This method must not be called in the sending fiber.

    ***************************************************************************/

    public void shutdown ( Exception e, RequestId request_id = 0 ) // nothrow
    in
    {
        assert(!this.send_loop.running);
    }
    body
    {
        if (request_id)
        {
            this.send_loop.unregisterForSending(request_id);
            this.recv_loop.unregisterForReceiving(request_id);
        }

        if (this.send_loop.loop_started)
            this.send_loop.resume(this.send_loop.fiber_token.get(), this,
                this.send_loop.Message(e));
    }

    public MessageParser message_parser ( )
    {
        return this.parser;
    }

    /***************************************************************************

        To be used when a protocol error is detected anywhere.

        Returns:
            the shared & reused `ProtocolError` exception object.

    ***************************************************************************/

    public ProtocolError protocol_error ( )
    {
        return this.protocol_error_;
    }

    /***************************************************************************

        Performs the connection shutdown.

        This method should not throw.

        Params:
            e = the exception reflecting the error

        In:
            This method must only be called in the send fiber and outside the
            sending loop.

    ***************************************************************************/

    protected void shutdownImpl ( Exception e ) // nothrow
    in
    {
        assert(this.send_loop.running);
        assert(!this.send_loop.loop_started);
    }
    body
    {
        this.current_exception = e;

        scope (exit) this.current_exception = null;

        this.recv_loop.connection_closed = true;
        if ( this.recv_loop.loop_started && this.recv_loop.waiting )
        {
            this.recv_loop.kill();
        }

        /*
         * Note that closing the socket automatically  unregisters it in epoll.
         * socket.close() should not throw. We don't handle its errors because
         * it is unclear how.
         * TODO: IConnectionHandler calls socket.close(), too, remove it from
         * there.
         */
        this.socket.close();
        if ( this.is_registered() )
            this.unregistered(); // ISelectClient method
        this.events_ = this.events_.init;

        this.send_loop.unregisterAll(
            (ref RequestId id)
            {
                this.recv_loop.unregisterForReceiving(id);
                this.notifyShutdown(id, e);
                return 0;
            }
        );

        this.recv_loop.unregisterAll(
            (ref RequestId id)
            {
                this.notifyShutdown(id, e);
                return 0;
            }
        );

    }

    /***************************************************************************

        Called (by SendLoop) with a request id that was just popped from the
        message queue. The subclass should call `send` once, passing the payload
        of the message this request wants to send. Should the request not exist
        any more, for whatever reason, then the subclass should not call `send`.

        Params:
            id   = the request id
            send = the output delegate to call once with the message payload

    ***************************************************************************/

    abstract protected void getPayloadForSending ( RequestId id,
        void delegate ( void[][] payload ) send );

    /***************************************************************************

        Called (by ReceiveLoop) when a request message has arrived.

        Params:
            id   = the request id
            send = the request message payload

    ***************************************************************************/

    abstract protected void setReceivedPayload ( RequestId id, Const!(void)[] payload );

    /***************************************************************************

        Called for all request ids in the message queue and the registry of
        those waiting for a message to arrive when `shutdown` was called so that
        these requests are aborted.

        `shutdown` is called by this class if an I/O or protocol error happens.
        The subclass can call shutdown, too.

        If a request id is in both the message queue and the registry of
        receivers then this method is called ony once with that request id.

        This method should not throw.

        Params:
            id = the request id
            e  = the exception reflecting the reason for the shutdown

    ***************************************************************************/

    abstract protected void notifyShutdown ( RequestId id, Exception e ); // nothrow

    /***************************************************************************

        Registers the socket either for input only or for both input and output.

        Params:
            output = false: register only for input
                     true: register for both input and output

    ***************************************************************************/

    protected void registerEpoll ( bool output )
    {
        auto events = cast(Event)(Event.EPOLLIN | Event.EPOLLRDHUP
            | (output? Event.EPOLLOUT : 0));

        if (this.events_ != events)
        {
            this.events_ = events;
            this.epoll.register(this);
        }
    }

    /**************************************************************************

        Handles an epoll event by resuming the send and/or receive fiber.

        Note that error events are caught by the `EpollSelectDispatcher` and
        reported via `this.error_()`.

        Params:
            events = events for the socket reported by epoll

        Returns:
            always true to keep the socket registered.

     **************************************************************************/

    override protected bool handle ( Event events ) // nothrow
    {
        debug ( SelectFiber )
        {
            Stderr.formatln("{}.handle: fd {} events {:X}",
                    typeof(this).stringof, this.socket.fd, cast(int)events);

            scope (success) Stderr.formatln("{}.handle: fd {} fiber suspended",
                typeof(this).stringof, this.socket.fd);
            scope (failure) Stderr.formatln("{}.handle: fd {} exception",
                typeof(this).stringof, this.socket.fd);
        }

        if ((events & (events.EPOLLIN | events.EPOLLRDHUP))
            && this.recv_loop.loop_started)
        {
            this.recv_loop.resume(
                this.recv_loop.fiber_token.get(), this,
                recv_loop.Message(events & ~events.EPOLLOUT)
            );
        }

        if ((events & events.EPOLLOUT) && this.send_loop.loop_started)
        {
            this.send_loop.resume(
                this.send_loop.fiber_token.get(), this,
                this.send_loop.Message(events & ~events.EPOLLIN)
            );
        }

        return true;
    }

    /***************************************************************************

        Shuts the connection down if epoll reports an error event for the
        socket.

    ***************************************************************************/

    override protected void error_ ( Exception exception, Event event )
    {
        this.shutdown(exception);
    }

    /***************************************************************************

        Returns:
            the events to register the socket for.

    ***************************************************************************/

    override public Event events ( )
    {
        return this.events_;
    }

    /**************************************************************************

        Returns:
            the socket file descriptor (a.k.a. handle).

     **************************************************************************/

    override public Handle fileHandle ( )
    {
        return this.socket.fileHandle();
    }

    /**************************************************************************

        Returns:
            the current socket error or 0 if none.

     **************************************************************************/

    override public int error_code ( )
    {
        return this.socket.error;
    }
}
