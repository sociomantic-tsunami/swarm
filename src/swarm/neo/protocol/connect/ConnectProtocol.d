/*******************************************************************************

    Helper for sequential (half duplex) client-node message exchange.

    Copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.protocol.connect.ConnectProtocol;

/******************************************************************************/

import ocean.io.select.client.model.ISelectClient;

/******************************************************************************/

class ConnectProtocol: ISelectClient
{
    import swarm.neo.protocol.Message: MessageType;
    import swarm.neo.protocol.ProtocolError;

    import swarm.neo.protocol.socket.MessageReceiver;
    import swarm.neo.protocol.socket.MessageSender;
    import swarm.neo.protocol.MessageParser;

    import swarm.neo.util.MessageFiber;
    import swarm.neo.util.FiberTokenHashGenerator;
    import swarm.neo.util.Util;

    import ocean.io.select.EpollSelectDispatcher;

    import ocean.core.Traits: hasIndirections;

    import ocean.stdc.posix.sys.socket;

    import core.stdc.errno: ENOENT;

    import ocean.transition;

    /***************************************************************************

        Socket file descriptor.

    ***************************************************************************/

    private Handle socket_fd;

    /***************************************************************************

        Epoll select dispatcher.

    ***************************************************************************/

    private EpollSelectDispatcher epoll;

    /***************************************************************************

        The fiber to suspend to wait for I/O completion.

    ***************************************************************************/

    private MessageFiber fiber;

    /***************************************************************************

        Fiber token generator.

    ***************************************************************************/

    private FiberTokenHashGenerator fiber_token_hash;

    /***************************************************************************

        Message receiver.

    ***************************************************************************/

    private MessageReceiver receiver;

    /***************************************************************************

        Message sender.

    ***************************************************************************/

    private MessageSender sender;

    /***************************************************************************

        Message parser.

    ***************************************************************************/

    private MessageParser parser;

    /***************************************************************************

        Exception to throw on protocol error.

    ***************************************************************************/

    private ProtocolError protocol_e;

    /***************************************************************************

        The request type to use for outgoing and to expect for incoming messages

    ***************************************************************************/

    private MessageType request_type;

    /***************************************************************************

        The I/O events we want to be notified about by epoll when any of them
        happens on the socket associated with this.socket_fd.

    ***************************************************************************/

    private Event events_ = Event.init;

    /***************************************************************************

        Initialises this instance.

        Params:
            request_type = the request type to use for outgoing and to expect
                           for incoming messages
            protocol_e   = exception instance to throw on protocol error
            epoll        = epoll select dispatcher
            fiber        = the fiber to suspend to wait for I/O completion
            socket_fd    = socket file descriptor
            receiver     = message receiver
            sender       = message sender

    ***************************************************************************/

    public void initialise ( MessageType request_type, ProtocolError protocol_e,
                  EpollSelectDispatcher epoll, MessageFiber fiber,
                  int socket_fd, MessageReceiver receiver, MessageSender sender )
    {
        this.events_ = Event.init;
        this.request_type = request_type;
        this.epoll = epoll;
        this.fiber = fiber;
        this.receiver = receiver;
        this.parser.e = this.protocol_e = protocol_e;
        this.sender = sender;
        this.socket_fd = cast(Handle)socket_fd;
    }

    /***************************************************************************

        Sends the protocol version.
        This method may only be called if the sender has not been used yet. All
        send*() methods of this class use the sender.

        Params:
            protocol_version = the protocol version to send

        Throws:
            - ProtocolError if the remote hung up the socket.
            - IOError on I/O or socket error.

    ***************************************************************************/

    public void sendProtocolVersion ( ubyte protocol_version )
    {
        if (this.sender.assignProtocolVersion(protocol_version))
        {
            this.registerEpoll(Event.EPOLLOUT);
            this.sender.finishSending(this.wait());
        }
    }

    /***************************************************************************

        Sends the protocol version.
        This method may only be called if the receiver has not been used yet.
        All receive*() methods of this class use the receiver.

        Returns:
            the receoved protocol version.

        Throws:
            - ProtocolError if the remote hung up the socket.
            - IOError on I/O or socket error.

    ***************************************************************************/

    public ubyte receiveProtocolVersion ( )
    {
        return this.receiver.receiveProtocolVersion(
            {
                this.registerEpoll(Event.EPOLLIN | Event.EPOLLRDHUP);
                return this.wait();
            }()
        );
    }

    /***************************************************************************

        Sets up this.protocol_error_ with a message containing the server and client
        protocol version.

        Params:
            client_timestamp = client time stamp
            node_timestamp   = client time stamp

        Returns:
            this.protocol_error_.

    ***************************************************************************/

    public void checkVersion (
        ubyte client_protocol_version, ubyte node_protocol_version,
        istring file = __FILE__, typeof(__LINE__) line = __LINE__
    )
    {
        if (client_protocol_version != node_protocol_version)
        {
            char[2] hex_buf;

            char[] hexVersion ( ubyte ver )
            {
                foreach_reverse (ref c; hex_buf)
                {
                    c = "0123456789ABCDEF"[ver & 0xF];
                    ver >>= 4;
                }
                return hex_buf[];
            }

            throw this.protocol_e
                .set("The client uses protocol version 0x", file, line)
                .append(hexVersion(client_protocol_version))
                .append(", which is incompatible to node protocol version 0x")
                .append(hexVersion(node_protocol_version));
        }
    }

    /***************************************************************************

        Sends a message using fields as the body. The request type is
        this.request_type. Each field must be either a value type (the
        corresponding element of fields is a pointer to it) or a dynamic array
        of a value type. There must be at least one field.
        In the message body the fields are sequential without padding. Each
        dynamic array is preceded with a size_t field containing the array
        length (number of elements).
        As an exception, if there is only one field, and it is a dynamic array,
        the array length is not included. The message body then consists of that
        array.

        Each type in Fields must be either
          - a pointer to a value type or
          - a dynamic array of a value type.

        Params:
            fields = the fields for the message body

        Throws:
            - ProtocolError if the remote hung up the socket.
            - IOError on I/O or socket error.

    ***************************************************************************/

    public void send ( Fields ... ) ( Fields fields )
    {
        mixin(
            "bool finish_sending = this.sender.assign(" ~
                 "this.request_type,(void[][]).init," ~
                 TupleToSlices!(Fields)("fields") ~
            ");"
        );

        if (finish_sending)
        {
            this.registerEpoll(Event.EPOLLOUT);
            this.sender.finishSending(this.wait());
        }

        this.sender.flush();
    }

    /***************************************************************************

        Receives a message, expecting raw data of a value of type Field as the
        body. The expected request type is this.request_type.

        Template Params:
            Field = the expected type of the message body data

        Returns:
            the value of the field in the message body.

        Throws:
            - ProtocolError on message parsing error or if the remote hung up
              the socket.
            - IOError on I/O or socket error.

    ***************************************************************************/

    public Field receiveValue ( Field ) ( )
    {
        static assert(!hasIndirections!(Field));
        Field value;
        this.receive_(
            (Const!(void)[] message_body)
            {
                this.parser.parseBody!(Field)(message_body, value);
            }
        );
        return value;
    }

    /***************************************************************************

        Receives a message, expecting the body to consist of fields of types
        Fields and calls dg with the fields. The expected request type is
        this.request_type.
        Each field must be either a value type or a dynamic array of a value
        type. There must be at least one field.
        As an exception, if there is only one field, and it is a dynamic array,
        the array length is not included. The message body is then then expected
        to consist of that array. A single void[] field simply obtains the full
        raw message body.

        Each type in Fields must be either
          - a value type or
          - a dynamic array of a value type.

        Params:
            dg = output delegate to call with the message body fields. The
                 fields are valid only until dg returns.

        Throws:
            - ProtocolError on message parsing error or if the remote hung up
              the socket.
            - IOError on I/O or socket error.

    ***************************************************************************/

    public void receive ( Fields ... ) ( void delegate ( Fields fields ) dg )
    {
        this.receive_(
            (Const!(void)[] message_body)
            {
                Fields fields;
                this.parser.parseBody!(Fields)(message_body, fields);
                dg(fields);
            }
        );
    }

    /***************************************************************************

        Receives a message and calls dg with the message body.

        Params:
            dg = output delegate to call with the message body. The message body
                 is valid only until dg returns.

        Throws:
            - ProtocolError on message parsing error or if the remote hung up
              the socket.
            - IOError on I/O or socket error.

    ***************************************************************************/

    private void receive_ ( void delegate ( Const!(void)[] message_body ) dg )
    {
        this.receiver.receive(
            {
                this.registerEpoll(Event.EPOLLIN | Event.EPOLLRDHUP);
                return this.wait();
            }(),
            (MessageType type, Const!(void)[] message_body)
            {
                this.protocol_e.enforce(type == this.request_type, "request type mismatch");
                dg(message_body);
            },
            true // receive only one message
        );
    }

    /***************************************************************************

        Registers this instance with epoll if not registered yet, or changes the
        registration if events is different from the last call of this method.

        Unregistration is done in the destructor.

        Params:
            events = the events to register for

        Throws:
            EpollException if epoll_ctl() failed with
             - EBADF, EINVAL, EPERM, EEXIST, which would indicate a bug, or
             - ENOMEM, ENOSPC, which are fatal resource exhaustion errors.
            ENOENT is handled internally.

    ***************************************************************************/

    public void registerEpoll ( Event events )
    {
        if (this.events_ != events)
        {
            this.events_ = events;
            this.epoll.register(this);
        }
    }

    /***************************************************************************

        Unregister this instance from epoll.

    ***************************************************************************/

    public void unregisterEpoll ( )
    {
        try
        {
            switch (this.epoll.unregister(this))
            {
                case 0, ENOENT:
                    break;
                default: // includes EBADF
                    // TODO: log error
            }
        }
        catch (Exception e)
        {
            // TODO: log error
        }
    }

    /***************************************************************************

        Suspends the fiber to wait for I/O events to happen on the socket
        associated with this.socket_fd. The fiber is resumed in handle().

        Returns:
            the events reported by epoll for the socket associated with
            this.socket_fd.

        Throws:
            Exception if an error event was reported.

    ***************************************************************************/

    public Event wait ( )
    {
        return cast(Event)
            this.fiber.suspend(this.fiber_token_hash.create(false), this).num;
    }

    /**************************************************************************

        Returns:
            the socket file descriptor.

     **************************************************************************/

    override public Handle fileHandle ( )
    {
        return this.socket_fd;
    }

    /**************************************************************************

        Returns:
            the events to register the socket for.

     **************************************************************************/

    override public Event events ( )
    {
        return this.events_;
    }

    /***************************************************************************

        I/O event handler. Resumes the fiber.

        Params:
            events = the events reported by epoll

        Returns:
            always true to stay registered.

     ***************************************************************************/

    override public bool handle ( Event events )
    {
        // TODO: as long as this returns true (it does) and never throws, we can
        // be sure that only informational methods of the client will be called
        // by SelectedKeys handler after this method exits.
        // I'm not sure we can guarantee that, though, as resume() may throw an
        // exception which was passed to the subsequent suspend().

        // TODO: Pass exception on error event
        this.fiber.resume(this.fiber_token_hash.get(), this,
            this.fiber.Message(events));
        return true;
    }

    /**************************************************************************

        Finalize method, called after this instance has been unregistered from
        the Dispatcher. Intended to be overridden by a subclass if required.

        Params:
            status = status why this method is called

     **************************************************************************/

    override public void finalize ( FinalizeStatus status )
    {
        fiber.Message msg;
        msg.exc = new Exception("ConnectProtocol: finalized"); // TODO: reusable exception
        this.fiber.resume(this.fiber_token_hash.get(), this, msg);
    }

    /***************************************************************************

        Obtains the current error code of the underlying socket. Called from
        ocean.io.select.selector.SelectedKeysHandler when an error event occurs
        for this client in epoll.

        Returns:
            the current error code of the socket.

    ***************************************************************************/

    override public int error_code ( )
    {
        int errnum;

        socklen_t n = errnum.sizeof;

        return !getsockopt(this.socket_fd, SOL_SOCKET, SO_ERROR, &errnum, &n)? errnum : 0;
    }
}
