/*******************************************************************************

    Non-blocking socket message input.

    Reads messages from a socket, stores them in an internal buffer, parses them
    and passes each message to a caller-supplied callback delegate.

    This class is suitable for both half and full duplex because it does not
    handle epoll notifications directly (it is not a select client).

    Copyright: Copyright (c) 2010-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.protocol.socket.MessageReceiver;

/*******************************************************************************

    This base class contains everything -- data buffering and message parsing --
    except the actual socket I/O, which is implemented in `MessageReceiver`.
    This separation is to allow for unit testing data buffering and message
    parsing without needing a socket.

*******************************************************************************/

private class MessageReceiverBase
{
    import swarm.neo.protocol.Message: MessageType, MessageHeader;
    import swarm.neo.protocol.MessageParser;
    import swarm.neo.protocol.ProtocolError;

    import ocean.sys.Epoll: Epoll;

    import swarm.neo.util.MessageFiber;
    alias MessageFiber.KilledException KilledException;

    import core.stdc.string: memmove;

    import ocean.core.Traits: hasIndirections;
    import ocean.core.Enforce: enforce;

    import swarm.neo.protocol.socket.IOStats;

    import ocean.transition;

    debug (Raw) import ocean.io.Stdout: Stderr;

    /***************************************************************************

        Convenience alias.

    ***************************************************************************/

    alias Epoll.Event Event;

    /***************************************************************************

        Message and socket input statistics.

    ***************************************************************************/

    public IOStats io_stats;

    /***************************************************************************

        Message parser.

    ***************************************************************************/

    private MessageParser parser;

    protected ProtocolError protocol_e;

    /***************************************************************************

        Receive buffer.

    ***************************************************************************/

    protected void[] buffer;

    /***************************************************************************

        The byte length of valid data in this.buffer.

    ***************************************************************************/

    protected size_t buffer_content_end = 0;

    /**************************************************************************/

    invariant ( )
    {
        assert(this.buffer_content_end <= this.buffer.length);
    }

    /***************************************************************************

        Constructor.

        Params:
            socket = input socket
            parser = message parser

    ***************************************************************************/

    public this ( ProtocolError protocol_e )
    {
        this.buffer = new ubyte[0x10000];
        this.parser.e = this.protocol_e = protocol_e;
    }

    /***************************************************************************

        Reads the one-byte client protocol version information from the socket.
        This is to be done only on a new client connection.

        Params:
            wait = should block until the socket is ready for reading and return
                   the epoll events reported for the socket

        Returns:
            the byte read from the socket.

        Throws:
            - ProtocolError on protocol error: The client
              - sent more data immediately after the protocol version or
              - closed the socket connection (EOF or socket hung-up);
            - IOError on I/O or socket error.

            Note that wait may throw as well.

        In:
            The internal receive buffer must be empty (which it is if no data
            have been received from the socket so far).

        Out:
            The internal receive buffer is empty.

    ***************************************************************************/

    public ubyte receiveProtocolVersion ( lazy Event wait )
    in
    {
        assert(!this.buffer_content_end);
    }
    out
    {
        assert(!this.buffer_content_end);
    }
    body
    {
        this.ensureMinimumAmountOfBytesInBuffer(ubyte.sizeof, wait);

        scope (exit) this.buffer_content_end = 0;

        this.protocol_e.enforce(this.buffer_content_end == ubyte.sizeof,
                                "Client sent data immediately after the protocol version");

        return *cast(ubyte*)(this.buffer[0 .. ubyte.sizeof].ptr);
    }

    /***************************************************************************

        Receives one or more messages, parses them and passes them to dg.

        For dg note the following:
          - The msg_body passed to dg is valid only until dg returns/throws.
          - dg should throw only on fatal errors that break the protocol.

        Use one_message = true only under special circumstances where a
        half-duplex message node/client exchange is needed. It is always safe
        but causes extra memmove work which is unnecessary for full-duplex mode.

        Params:
            wait        = should block until the socket is ready for reading and
                          return the epoll events reported for the socket
            dg          = message output delegate
            one_message = true: call dg only once; false: call dg at least once
                          (i.e. call dg for all received messages).

        Throws:
            - ProtocolError on protocol error:
              - Message parsing or validation failed or
              - the client closed the socket connection (EOF or socket hung-up);
            - IOError on I/O or socket error.

            Note that wait and dg may throw as well.

    ***************************************************************************/

    public void receive ( lazy Event wait,
        void delegate ( MessageType type, Const!(void)[] msg_body ) dg,
        bool one_message = false )
    {
        scope (failure) this.buffer_content_end = 0;

        /*
         * this.buffer[0 .. this.buffer_content_end] may contain a partial
         * message left over by the previous call of this method. Read from the
         * socket so that this.buffer is populated with at least one complete
         * message.
         */
        MessageHeader header = this.receiveMessage(wait);

        /*
         * Pass the first message, which starts at this.buffer[0], to dg. pos is
         * the buffer position where the current message ends.
         */
        size_t pos = header.sizeof + header.body_length;
        dg(header.type, this.buffer[header.sizeof .. pos]);
        this.io_stats.msg_body.countBytes(pos - header.sizeof);

        if (!one_message)
        {
            while (true)
            {
                // Check if there is a complete message header.
                size_t header_end = pos + header.sizeof;
                if (header_end > this.buffer_content_end)
                    break;

                // Yes: Parse it and check if there is a complete message body.
                header = this.parseHeader(this.buffer[pos .. header_end]);

                size_t body_end = header_end + header.body_length;
                if (body_end > this.buffer_content_end)
                    break;

                // Yes: Pass it to dg, and adjust pos for the next cycle.
                dg(header.type, this.buffer[header_end .. body_end]);
                this.io_stats.msg_body.countBytes(body_end - header_end);
                pos = body_end;
            }
        }

        /*
         * The tail of this.buffer (this.buffer[pos .. this.buffer_content_end])
         * may contain a partial message. Move these data to the front of the
         * buffer to be continued on the next call of this method.
         */
        this.cutBufferHead(pos);
    }

    /***************************************************************************

        Obtains the message header from the beginning of `message` and validates
        it.

        Params:
            message = the message to get the header from

        Returns:
            the message header

        Throws:
            ProtocolError if validating the header failed.

    ***************************************************************************/

    private MessageHeader parseHeader ( Const!(void)[] message )
    {
        auto header = *this.parser.getValue!(MessageHeader)(message);
        header.validate(this.protocol_e);
        return header;
    }

    /***************************************************************************

        Reads data from the socket so that this.buffer contains at least one
        full message, parsing the message header.

        After this method has returned the header,

            this.buffer[0 .. header.sizeof + header.body_length]

        contains the message body, and

            this.buffer[header.sizeof + header.body_length .. this.buffer_content_end]

        contains subsequent, potentially partial messages.

        Params:
            wait = should block until the socket is ready for reading and return
                   the epoll events reported for the socket

        Throws:
            - ProtocolError on protocol error:
              - Message parsing or validation failed or
              - the client closed the socket connection (EOF or socket hung-up);
            - IOError on I/O or socket error.

    ***************************************************************************/

    private MessageHeader receiveMessage ( lazy Event wait )
    out (header)
    {
        assert(this.buffer_content_end >= header.sizeof + header.body_length);
    }
    body
    {
        /*
         * this.buffer[0 .. this.buffer_content_end] contains a partial message,
         * starting with the header. The header may not be complete, i.e.
         * this.buffer_content_end < MessageHeader.sizeof;
         * this.buffer_content_end may even be 0.
         * Read the full header and potentially more data, which would be the
         * beginning of or even the full message body and following messages.
         */
        this.ensureMinimumAmountOfBytesInBuffer(MessageHeader.sizeof, wait);
        MessageHeader header = this.parseHeader(this.buffer[0 .. MessageHeader.sizeof]);

        /*
         * Read the full message body and potentially more data.
         */
        this.ensureMinimumAmountOfBytesInBuffer(header.sizeof + header.body_length, wait);

        /*
         * this.buffer[header.sizeof .. header.sizeof + header.body_length]
         * now contains the message body.
         */
        return header;
    }

    /***************************************************************************

        Cuts off `this.buffer[0 .. n]`, i.e. moves
        `this.buffer[n .. this.buffer_content_end]` to
        `this.buffer[0 .. this.buffer_content_end - n]` and adjusts
        `this.buffer_content_end`.
        If `n == this.buffer_content_end` then no data are actually moved.

        Params:
            n = the length of the head in this.buffer to cut off

        In:
            n may be at most this.buffer_content_end.

    ***************************************************************************/

    private void cutBufferHead ( size_t n )
    in
    {
        assert(n <= this.buffer_content_end);
    }
    body
    {
        this.buffer_content_end -= n;

        // Don't memmove if there are no data to move. This also protects from
        // an array bounds error if n == this.buffer.length.
        if (this.buffer_content_end)
        {
            memmove(&this.buffer[0], &this.buffer[n],
                    this.buffer_content_end);
        }
    }

    /***************************************************************************

        Ensures that this.buffer contains at least the specified minimum number
        of bytes, reading more data from the socket if the buffer does not
        contain enough data, until this.buffer contains at least bytes_requested
        bytes. Increases this.buffer_content_end to bytes_requested if less (but
        does not decrease it the buffer already contains more data). Evaluates
        wait() if a read() call receives less than the needed amount of data.

        Params:
            bytes_requested = the minimum required amount of bytes in
                              this.buffer
            wait            = should block until the socket is ready for reading
                              and return the epoll events reported for the
                              socket

        Throws:
            - ProtocolError if the client closed the socket connection (EOF or
              socket hung-up);
            - IOError on I/O or socket error.

        Out:
            this.buffer_content_end is at least bytes_requested.

    ***************************************************************************/

    private void ensureMinimumAmountOfBytesInBuffer ( size_t bytes_requested, lazy Event wait )
    in
    {
        assert(this); // invariant
    }
    out
    {
        assert(bytes_requested <= this.buffer_content_end);
        assert(this); // invariant
    }
    body
    {
        if (this.buffer_content_end < bytes_requested)
        {
            if (this.buffer.length < bytes_requested)
                this.buffer.length = bytes_requested;

            this.read();

            while (this.buffer_content_end < bytes_requested)
            {
                this.io_stats.num_iowait_calls++;
                this.read(wait);
            }
        }
    }

    /**************************************************************************

        Reads data from the socket and appends them to the data buffer.

        Params:
            events = events reported for the input device

        Returns:
            the number of bytes read, 0 if no data were available.

        Throws:
            - ProtocolError if the client closed the socket connection (EOF or
              socket hung-up);
            - IOError on I/O or socket error.

     **************************************************************************/

    abstract protected size_t read ( Event events = Event.EPOLLIN );
}

/*******************************************************************************

    The actual socket message receiver class.

*******************************************************************************/

class MessageReceiver: MessageReceiverBase
{
    import swarm.neo.protocol.ProtocolError;

    import ocean.io.select.protocol.generic.ErrnoIOException: IOError;

    import unistd = core.sys.posix.unistd: read;
    import ocean.sys.socket.model.ISocket;
    import core.stdc.errno: errno, EAGAIN, EWOULDBLOCK, EINTR;


    /***************************************************************************

        The socket to read from.

    ***************************************************************************/

    private ISocket socket;

    /***************************************************************************

        Exception thrown on I/O or socket error.

    ***************************************************************************/

    private IOError error_e;

    /***************************************************************************

        Constructor.

        Params:
            socket = input socket
            parser = message parser

    ***************************************************************************/

    public this ( ISocket socket, ProtocolError protocol_e )
    {
        super(protocol_e);
        this.socket = socket;
        this.error_e = new IOError(this.socket);
    }

    /**************************************************************************

        Reads data from the socket and appends them to the data buffer.

        Params:
            events = events reported for the input device

        Returns:
            the number of bytes read, 0 if no data were available.

        Throws:
            - ProtocolError if the client closed the socket connection (EOF or
              socket hung-up);
            - IOError on I/O or socket error.

        Note: POSIX says the following about the return value of read():

            When attempting to read from an empty pipe or FIFO [remark: includes
            sockets]:

            - If no process has the pipe open for writing, read() shall return 0
              to indicate end-of-file.

            - If some process has the pipe open for writing and O_NONBLOCK is
              set, read() shall return -1 and set errno to [EAGAIN].

            - If some process has the pipe open for writing and O_NONBLOCK is
              clear, read() shall block the calling thread until some data is
              written or the pipe is closed by all processes that had the pipe
              open for writing.

        @see http://pubs.opengroup.org/onlinepubs/009604499/functions/read.html

     **************************************************************************/

    override protected size_t read ( Event events = Event.EPOLLIN )
    in
    {
        assert(this);
        assert(events & events.EPOLLIN,
               typeof(this).stringof ~ ".write: called without EPOLLIN event");
        assert(this.buffer_content_end < this.buffer.length, "requested to receive nothing");
    }
    out
    {
        assert(this);
    }
    body
    {
        void[] dst = this.buffer[this.buffer_content_end .. $];

        errno = 0;

        socket.ssize_t n = unistd.read(this.socket.fd, dst.ptr, dst.length);

        if (n > 0)
        {
            debug (Raw) Stderr.formatln("[{}] Read {:X2} ({} bytes)",
                this.socket.fileHandle,
                dst[0 .. n], n);

            this.buffer_content_end += n;
            this.io_stats.socket.countBytes(n);
            return n;
        }
        else
        {
            this.io_stats.socket.countBytes(0);

             // EOF or error: Check for socket error and hung-up event first.

            this.error_e.checkDeviceError(n? "read error" : "end of flow whilst reading");

            this.error_e.enforce(!(events & events.EPOLLRDHUP), "connection hung up on read");
            this.error_e.enforce(!(events & events.EPOLLHUP), "connection hung up");
            // n == 0 indicates EOF and no socket error or hung-up event: Throw
            // EOF warning. If the socket is connected and there are just no
            // data available right now then n < 0 and
            // errno = EAGAIN/EWOULDBLOCK/EINTR.
            this.error_e.enforce(n != 0, "end of flow whilst reading");

            switch (errno)
            {
                case EINTR, EAGAIN:
                    static if ( EAGAIN != EWOULDBLOCK )
                    {
                        case EWOULDBLOCK:
                    }

                    // EAGAIN/EWOULDBLOCK: currently no data available.
                    // EINTR: read() was interrupted by a signal before data
                    //        became available.

                    return 0;

                default:
                    throw this.error_e.set(errno).addMessage("read error");
            }
        }
    }
}

unittest
{
    /*
     * For testing we generate a sequence of messages with random body lengths
     * of each 60 - 100 bytes and store them in a buffer. On each call `read()`
     * reads a fixed size chunk from that message sequence data.
     * The body of each message starts with a serialised `Info` struct,
     * containing the serial number id and the body length of the message. The
     * rest of the message body is stomped with the string "UNITTEST".
     * The sequence of the message body lengths is generated using the POSIX
     * `drand48` pseudorandom number generator family seeded with 0 so that the
     * sequence is always the same.
     */
    static class MessageReceiverTest: MessageReceiverBase
    {
        import swarm.neo.protocol.Message: MessageType, MessageHeader;
        import swarm.neo.protocol.ProtocolError;

        import ocean.core.Test;
        import core.sys.posix.stdlib: erand48;
        import ocean.transition;

        // Information stored in the message body, at the beginning
        static struct Info
        {
            uint id, length;
        }

        // The magic string to stomp the rest of the message body with
        const magic = "UNITTEST"[];

        const msg_len_min = 60,
              msg_len_max = 100;

        // The buffer containing the sequence of messages
        ubyte[] messages;

        // The number of bytes `read()` should read on each call; set by
        // `runTest()`
        size_t read_chunk_size;

        // The number of bytes `read()` has already read from `messages`
        size_t data_read = 0;

        // Generates the sequence of messages, storing them in `this.messages`.
        // Calculats the body length of the last message so that
        // `this.messages.length == this.buffer.length`.
        this ( )
        {
            super(new ProtocolError);

            ushort[3] xsubi = 0; // random number generator state
            uint id;

            for (id = 1;
                 this.buffer.length >= this.messages.length +
                                       MessageHeader.sizeof + msg_len_max;
                 id++)
            {
                auto n = msg_len_min + cast(uint)
                    (erand48(xsubi) * (msg_len_max - msg_len_min + 1));
                assert(n >= msg_len_min);
                assert(n <= msg_len_max);
                n += MessageHeader.sizeof;
                auto start = this.messages.length;
                this.messages.length = start + n;
                makeMsg(this.messages[start .. $], id);
            }

            auto n = this.buffer.length - this.messages.length;
            this.messages.length = this.buffer.length;
            makeMsg(this.messages[$ - n .. $], id);
        }

        // Populates `dst` with one message, `id` is the serial message id.
        static void makeMsg ( void[] dst, uint id )
        in
        {
            assert(dst.length >= MessageHeader.sizeof + Info.sizeof);
        }
        out
        {
            checkMsgBody(dst[MessageHeader.sizeof .. $], id);
        }
        body
        {
            // Write the message header
            auto msg_body = dst[MessageHeader.sizeof .. $];
            auto header = MessageHeader(MessageType.Request, msg_body.length);
            header.setParity();
            *cast(MessageHeader*)dst.ptr = header;

            // Write the Info to the beginning of the message body
            *cast(Info*)msg_body.ptr = Info(id, cast(ushort)msg_body.length);

            // Stomp the rest of the message body with the magic string
            for (msg_body = msg_body[Info.sizeof .. $];
                 msg_body.length >= magic.length;
                 msg_body = msg_body[magic.length .. $])
            {
                msg_body[0 .. magic.length] = cast(Const!(void)[])magic;
            }

            msg_body[] = cast(Const!(void)[])magic[0 .. msg_body.length];
        }

        // Checks if a message body is valid: `id` and `msg_body.length` should
        // match the info, and the remaining data should be stamped with the
        // magic string.
        static void checkMsgBody ( Const!(void)[] msg_body, uint id )
        {
            test!(">=")(msg_body.length, Info.sizeof);
            auto info = *cast(Info*)msg_body[0 .. Info.sizeof].ptr;
            test!("==")(info.id, id);
            test!("==")(info.length, msg_body.length);

            for (msg_body = msg_body[Info.sizeof .. $];
                 msg_body.length >= magic.length;
                 msg_body = msg_body[magic.length .. $])
            {
                test!("==")(msg_body[0 .. magic.length], magic);
            }

            test!("==")(msg_body, magic[0 .. msg_body.length]);
        }

        // Reads `this.read_chunk_size` bytes of data from `this.messages` and
        // appends them to the data buffer. If less than `read_chunk_size` bytes
        // are available then only the available data are read.
        override protected size_t read ( Event events = Event.EPOLLIN )
        {
            assert(this.read_chunk_size); // protect from an endless loop
            auto n = this.read_chunk_size;

            if (this.messages.length < (n + this.data_read))
            {
                n = this.messages.length - this.data_read;
            }

            this.buffer[this.buffer_content_end .. this.buffer_content_end + n]
                = this.messages[this.data_read .. this.data_read + n];
            this.buffer_content_end += n;
            this.data_read += n;
            return n;
        }

        // Tests `receive()` with `read()` reading `read_chunk_size` bytes per
        // call. Reads all generated messages and validates them.
        void runTest ( size_t read_chunk_size )
        in
        {
            assert(read_chunk_size);
            assert(read_chunk_size <= this.buffer.length);
        }
        body
        {
            this.read_chunk_size = read_chunk_size;
            this.data_read = 0;

            uint id = 1;
            while (this.data_read < this.messages.length)
            {
                this.receive(Event.init,
                    (MessageType type, Const!(void)[] msg_body)
                    {
                        test!("==")(type, type.Request);
                        checkMsgBody(msg_body, id++);
                    }
                );
            }

            this.buffer_content_end = 0;
        }
    }

    scope rcvtest = new MessageReceiverTest;

    rcvtest.runTest(0x200);
    rcvtest.runTest(rcvtest.buffer.length);
    rcvtest.runTest(rcvtest.MessageHeader.sizeof + rcvtest.msg_len_max - 10);
    rcvtest.runTest(10);
}
