/*******************************************************************************

    Non-blocking socket message output using TCP Cork.

    This class is suitable for both half and full duplex because it does not
    handle epoll notifications directly (it is not a select client).

    Once upon a time there was an explicit flush method. It relied on the
    TCP_CORK being set and it would then pull out and put the cork back in.
    However this wouldn't work, because putting the cork back in had to be done
    after all the packets are actually sent, otherwise the last incomplete packet
    would be delayed for the 200ms. Since we moved to the explicit application
    buffering for the large data and to the explicit flushing for the control
    messages this flush was deprecated. If there's a need to bring it in again,
    instead of TCP_CORK on/off, what it should do is to set the TCP_NODELAY
    on (which is overridden by TCP_CORK, but still forces explicit flush of all
    pending data). See https://github.com/sociomantic-tsunami/dmqproto/issues/48
    for more info.

    Copyright: Copyright (c) 2010-2017 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.neo.protocol.socket.MessageSender;

/******************************************************************************/

class MessageSender
{
    import swarm.neo.protocol.Message: MessageType, MessageHeader;
    import swarm.neo.protocol.socket.MessageGenerator;

    import ocean.sys.socket.model.ISocket;
    import ocean.sys.Epoll: Epoll;

    import ocean.io.select.protocol.generic.ErrnoIOException: IOError;

    import swarm.neo.protocol.socket.uio_const;
    import core.sys.posix.sys.socket: setsockopt;
    import core.sys.posix.netinet.in_: IPPROTO_TCP;
    static if (__VERSION__ >= 2078)
        import core.sys.linux.netinet.tcp: TCP_CORK;
    else
        import core.sys.linux.sys.netinet.tcp: TCP_CORK;
    import core.stdc.errno: errno, EAGAIN, EWOULDBLOCK, EINTR;

    import ocean.meta.types.Qualifiers;
    import ocean.core.Verify;

    debug (Raw) import ocean.io.Stdout: Stderr;

    import core.stdc.stdio: fputs, stderr;
    import core.stdc.stdlib: exit, EXIT_FAILURE;
    import swarm.neo.protocol.socket.IOStats;

    /***************************************************************************

        Message and socket output statistics.

    ***************************************************************************/

    public IOStats io_stats;

    /***************************************************************************

        Convenience alias.

    ***************************************************************************/

    alias Epoll.Event Event;

    /***************************************************************************

        The socket to write to.

    ***************************************************************************/

    private ISocket socket;

    /***************************************************************************

        The buffer for output data that writev() couldn't send in one call. This
        is only to avoid dangling slices on fiber race conditions. All sending
        methods return only after write() sent the full content of this buffer.

    ***************************************************************************/

    private void[] pending_data;

    /***************************************************************************

        Exception to be thrown on I/O or socket error.

    ***************************************************************************/

    private IOError error_e;

    /***************************************************************************

        Constructor.

        Params:
            socket     = output socket

    ***************************************************************************/

    public this ( ISocket socket )
    {
        this.socket = socket;
        this.error_e = new IOError(socket);
    }

    /**************************************************************************

        Sends protocol_version.

        Calls register before the first evaluation of wait, i.e. at most once.

        Params:
            protocol_version = the protocol version information to send
            register         = should register the socket for writing
            wait             = should block until the socket is ready for
                               writing and return the epoll events reported for
                               the socket

        Throws:
            - ProtocolError if the remote hung up,
            - IOError on I/O or socket error.

     **************************************************************************/

    public bool assignProtocolVersion ( ubyte protocol_version )
    {
        auto iov = iovec_const(&protocol_version, protocol_version.sizeof);
        auto tracker = IoVecTracker((&iov)[0 .. 1], iov.iov_len);
        return this.assign_(tracker);
    }

    private IoVecMessage iov_msg;

    /**************************************************************************

        Assigns a message, whose body consists of `static_fields` followed by
        `dynamic_fields`, for sending.
        Tries to send the message immediately with a non-blocking socket write
        operation and returns `false` if the message was sent. Otherwise, if the
        socket would block without sending the whole message, copies the
        remaining data into a buffer; call `finishSending` to finish sending the
        message.

        Do not call this method if data of a previous message are still in the
        buffer.

        Params:
            type           = the message type
            dynamic_fields = the last fields of the message body
            static_fields  = the first fields of the message body

        Returns:
            `false` if the message was sent or `true` if a `finishSending` call
            is required to finish sending the message.

        Throws:
            - ProtocolError if the remote hung up,
            - IOError on I/O or socket error.

     **************************************************************************/

    public bool assign ( MessageType type, in void[][] dynamic_fields, in void[][] static_fields ... )
    {
        auto tracker = this.iov_msg.setup(type, dynamic_fields, static_fields);
        this.io_stats.msg_body.add(tracker.length - MessageHeader.sizeof);
        return this.assign_(*tracker);
    }

    /**************************************************************************

        Finishes sending a message that was previously assigned via `assign` or
        `assignProtocolVersion`. Should be called if and only if a previous call
        of these methods returned `true`.

        Call this method after and only after a call of `assign` or
        `assignProtocolVersion` has returned `true`.

        Params:
            wait = should block until the socket is ready for writing and return
                   the epoll events reported for the socket

        Throws:
            - ProtocolError if the remote hung up,
            - IOError on I/O or socket error.

     **************************************************************************/

    public void finishSending ( lazy Event wait )
    out
    {
        assert(!this.pending_data.length);
    }
    body
    {
        verify(this.pending_data.length > 0, typeof(this).stringof ~
               ".finishSending: no message to send");

        auto iov = iovec_const(this.pending_data.ptr, this.pending_data.length);
        auto src = IoVecTracker((&iov)[0 .. 1], iov.iov_len);

        scope (exit)
        {
            this.pending_data.length = 0;
            assumeSafeAppend(this.pending_data);
        }

        do
            this.io_stats.num_iowait_calls++;
        while (!this.write(src, wait));
    }

    /***************************************************************************

        Assigns all data referenced by `src` for sending.
        Tries to send the data immediately with a non-blocking socket write
        operation and returns `false` if the message was sent. Otherwise, if the
        socket would block without sending the whole message, copies the
        remaining data into a buffer; call `finishSending` to finish sending the
        message.

        Do not call this method if data of a previous message are still in the
        buffer.

        Params:
            src = the output data vector & tracker

        Returns:
            `false` if the message was sent or `true` if a `finishSending` call
            is required to finish sending the message.

        Throws:
            - ProtocolError if the remote hung up,
            - IOError on I/O or socket error.

    ***************************************************************************/

    private bool assign_ ( ref IoVecTracker src )
    out (need_finish)
    {
        assert(need_finish || !this.pending_data.length);
    }
    body
    {
        verify(src.length > 0, typeof(this).stringof ~ ".assign_: empty message");
        verify(!this.pending_data.length, typeof(this).stringof ~
               ".assign_: the previous message hasn't been sent yet");

        // Try to write it all in one go, this is likely to succeed.
        if (!this.write(src))
        {
            // Couldn't write it in one go: Copy the remaining payload into
            // this.pending_data, register for becoming ready to write
            // and enter the write loop.
            src.moveTo(this.pending_data);
            return true;
        }
        else
        {
            return false;
        }
    }

   /**************************************************************************

        Attempts to write the data in src to the socket. The socket may or may
        not write all data.

        Params:
            src    = the output data vector & tracker
            events = events reported for the socket, if any

        Returns:
            true if all data have been sent or false to try again.

        Throws:
            - ProtocolError if the remote hung up,
            - IOError on I/O or socket error.

     **************************************************************************/

    private bool write ( ref IoVecTracker src, Event events = Event.EPOLLOUT )
    {
        verify((events & events.EPOLLOUT) != 0,
               typeof(this).stringof ~ ".write: called without EPOLLOUT event");
        verify(src.length > 0, "requested to send nothing");

        debug (Raw)
        {
            Stderr.format("[{}] Write ", this.socket.fileHandle);
            foreach (field; src.fields)
            {
                Stderr.format("{:X2}", field.iov_base[0 .. field.iov_len]);
            }
            Stderr.formatln("({} bytes)", src.length);
        }

        errno = 0;
// maybe do the vector I/O call + advance in IoVecTracker?
        socket.ssize_t n = sendv(this.socket.fd, src.fields, MSG_NOSIGNAL);

        if (n >= 0) // n == 0 cannot happen: write() returns it only if the
        {           // output data are empty, which we prevent in the precondition
            this.io_stats.socket.add(n);
            return !src.advance(n);
        }
        else
        {
            this.io_stats.socket.add(0);
            this.error_e.checkDeviceError("write error");

            this.error_e.enforce(!(events & events.EPOLLHUP), "connection hung up");

            int errnum = errno;

            switch (errnum)
            {
                case EINTR, EAGAIN:
                    static if ( EAGAIN != EWOULDBLOCK )
                    {
                        case EWOULDBLOCK:
                    }
                    return false;

                default:
                    this.error_e.enforce(false, "write error");
                    assert (false);
            }
        }
    }
}
