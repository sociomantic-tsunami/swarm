/*******************************************************************************

    Non-blocking socket message output using TCP Cork.

    This class is suitable for both half and full duplex because it does not
    handle epoll notifications directly (it is not a select client).

    Copyright: Copyright (c) 2010-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

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

    import core.sys.posix.sys.socket: setsockopt;
    import core.sys.posix.sys.uio: iovec, writev;
    import core.sys.posix.netinet.in_: IPPROTO_TCP;
    import core.sys.linux.sys.netinet.tcp: TCP_CORK;
    import core.stdc.errno: errno, EAGAIN, EWOULDBLOCK, EINTR;

    import ocean.transition;

    debug (Raw) import ocean.io.Stdout: Stderr;

    import core.sys.posix.signal: signal, SIGPIPE, SIG_IGN, SIG_ERR;
    import core.stdc.stdio: fputs, stderr;
    import core.stdc.stdlib: exit, EXIT_FAILURE;
    import swarm.neo.protocol.socket.IOStats;

    /***************************************************************************

        Message and socket output statistics.

    ***************************************************************************/

    public IOStats io_stats;

    /***************************************************************************

        Suppress the Broken Pipe signal for this process; `writev()` may trigger
        it otherwise. It is safe to suppress it for the whole process because it
        is useful only to abort if not handling I/O events.

    ***************************************************************************/

    static this ( )
    {
        if (signal(SIGPIPE, SIG_IGN) == SIG_ERR)
        {
            fputs("signal(SIGPIPE, SIG_IGN) failed\n".ptr, stderr);
            exit(EXIT_FAILURE);
        }
    }

    /***************************************************************************

        Convenience alias.

    ***************************************************************************/

    alias Epoll.Event Event;

    /***************************************************************************

        true if the TCP Cork feature is currently enabled or false otherwise.

    ***************************************************************************/

    private bool cork_ = false;

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
        auto iov = iovec(&protocol_version, protocol_version.sizeof);
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

    public bool assign ( MessageType type, void[][] dynamic_fields, void[][] static_fields ... )
    {
        auto tracker = this.iov_msg.setup(type, dynamic_fields, static_fields);
        this.io_stats.msg_body.countBytes(tracker.length - MessageHeader.sizeof);
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
    in
    {
        assert(this.pending_data.length, typeof(this).stringof ~
               ".finishSending: no message to send");
    }
    out
    {
        assert(!this.pending_data.length);
    }
    body
    {
        auto iov = iovec(this.pending_data.ptr, this.pending_data.length);
        auto src = IoVecTracker((&iov)[0 .. 1], iov.iov_len);

        scope (exit)
        {
            this.pending_data.length = 0;
            enableStomping(this.pending_data);
        }

        do
            this.io_stats.num_iowait_calls++;
        while (!this.write(src, wait));
    }

    /***************************************************************************

        Flushes the TCP Cork buffer.

        Note that apart from TCP Cork no output data buffering is done in this
        class: All sending methods return only after write() accepted all output
        data. If TCP Cork is enabled then write() may do internal buffering of
        the payload of one TCP frame; that buffer is flushed after 200 ms.
        See man 7 tcp.

    ***************************************************************************/

    public void flush ( )
    {
        if (this.cork_)
        {
            this.cork = false;
            this.cork = true;
        }
    }

    /***************************************************************************

        Enables or disables the TCP Cork feature.

        TCP Cork is a Linux feature to buffer output data for a TCP/IP
        connection until a full TCP frame (network packet) can be sent. It uses
        a timeout of 200ms. See man 7 tcp.

        No further output data buffering is done in this class: All sending
        methods return only after write() accepted all output data.

        Params:
            enabled = true: enable the TCP Cork option; false: disable it.
                      Disabling sends all pending data immediately.

        Returns:
            enable

        Throws:
            IOException on error setting the TCP Cork option.

    ***************************************************************************/

    public bool cork ( bool enable )
    {
        this.error_e.enforce(!this.socket.setsockoptVal(IPPROTO_TCP, TCP_CORK, enable), "unable to set TCP_CORK");
        this.cork_ = enable;
        return this.cork_;
    }

    /**************************************************************************

        Tells whether TCP Cork feature is currently enabled.

        Returns:
            true if TCP Cork is currently enabled or false otherwise.

     **************************************************************************/

    public bool cork ( )
    {
        return this.cork_;
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
    in
    {
        assert(src.length, typeof(this).stringof ~ ".assign_: empty message");
        assert(!this.pending_data.length, typeof(this).stringof ~
               ".assign_: the previous message hasn't been sent yet");
    }
    out (need_finish)
    {
        assert(need_finish || !this.pending_data.length);
    }
    body
    {
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
    in
    {
        assert(events & events.EPOLLOUT,
               typeof(this).stringof ~ ".write: called without EPOLLOUT event");
        assert(src.length, "requested to send nothing");
    }
    body
    {
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
        socket.ssize_t n = writev(this.socket.fd, src.fields.ptr, cast(int)src.fields.length);

        if (n >= 0) // n == 0 cannot happen: write() returns it only if the
        {           // output data are empty, which we prevent in the precondition
            this.io_stats.socket.countBytes(n);
            return !src.advance(n);
        }
        else
        {
            this.io_stats.socket.countBytes(0);
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
