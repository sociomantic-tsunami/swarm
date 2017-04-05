/*******************************************************************************

    Vector aka. scatter/gather I/O helpers.

    Copyright: Copyright (c) 2015-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.protocol.socket.MessageGenerator;

struct IoVecMessage // MessageGenerator
{
    import swarm.neo.protocol.Message: MessageType, MessageHeader;
    import ocean.core.Traits: hasIndirections;

    import ocean.transition;

    /***************************************************************************

        The tracker for readv()/writev().

    ***************************************************************************/

    IoVecTracker tracker;

    /***************************************************************************

        The message header.

    ***************************************************************************/

    MessageHeader header;

    /***************************************************************************

        Sets up the message. The message body consists of the concatenated
        `static_fields`, followed by the concatenated `dynamic_fields` (indeed
        in the reverse order of arguments).

        The returned tracker references this instance.

        Params:
            type           = the message type
            dynamic_fields = the last message fields
            static_fields  = the first message fields

        Returns:
            &this.tracker, the iovec tracker to be used with writev()/readv().

    ***************************************************************************/

    IoVecTracker* setup ( MessageType type, void[][] dynamic_fields, void[][] static_fields ... )
    in
    {
        assert(type <= type.max);
    }
    body
    {
        this.tracker.fields.length = 1 + static_fields.length + dynamic_fields.length;

        with (this.tracker.fields[0])
        {
            iov_base = &this.header;
            iov_len  = this.header.sizeof;
        }

        this.tracker.length = this.header.sizeof;

        foreach (i, ref iov_field; this.tracker.fields[1 .. 1 + static_fields.length])
        {
            iov_field.iov_base = static_fields[i].ptr;
            iov_field.iov_len = static_fields[i].length;
            this.tracker.length += iov_field.iov_len;
        }

        foreach (i, ref iov_field; this.tracker.fields[1 + static_fields.length .. $])
        {
            iov_field.iov_base = dynamic_fields[i].ptr;
            iov_field.iov_len = dynamic_fields[i].length;
            this.tracker.length += iov_field.iov_len;
        }

        this.header.type = type;
        this.header.body_length = this.tracker.length - this.header.sizeof;
        this.header.setParity();

        return &this.tracker;
    }


}

/*******************************************************************************

    Tracks the byte position if readv()/writev() didn't manage to transfer all
    data with one call.

    Usage example (but also read the writev manpage):
    ---
        // import writev, ssize_t

        int file_descriptor;
        // Open a file.

        IoVecTracker iov;
        // Set iov.fields to reference your I/O vector.
        // Set iov.length to the sum of all iov_len values in your I/O vector.

        while (iov.length)
        {
            ssize_t n = writev(file_descriptor, iov.fields.ptr,
                               cast(int)iov.fields.length);

            if (n > 0)
            {
                // writev() wrote n bytes
                iov.advance(n);
            }
            else
            {
                // n == 0: EOF (refer to the read()/write() manpage)
                // n < 0: Error
            }
        }
    ---

*******************************************************************************/

struct IoVecTracker
{
    import core.sys.posix.sys.uio: iovec;
    import ocean.transition: enableStomping;

    /***************************************************************************

        The vector of buffers. Pass to this.fields.ptr and this.fields.length to
        readv()/writev(). Note that advance() may modify the elements of this
        array; that is, it may change the pointers and lengths. (It does not
        modify the values referenced by the elements).

    ***************************************************************************/

    iovec[] fields;

    /***************************************************************************

        The remaining number of bytes to transfer.

    ***************************************************************************/

    size_t length;

    invariant ( )
    {
        assert(this.length || this.fields is null);
    }

    /***************************************************************************

        Adjusts this.fields and this.length after n bytes have been transferred
        by readv()/writev() so that this.fields.ptr and this.fields.length can
        be passed to the next call.

        Resets this instance if n == this.length, i.e. all data have been
        transferred at once. Does nothing if n is 0.

        Note that this method modifies the elements of this.fields

        Params:
            n = the number of bytes that have been transferred according to the
                return value of readv()/writev()

        Returns:
            the number of bytes remaining ( = this.length).

        In:
            n must be at most this.length.

    ***************************************************************************/

    size_t advance ( size_t n )
    in
    {
        assert(n <= this.length);
    }
    body
    {
        if (n)
        {
            if (n == this.length)
            {
                this.fields = null;
            }
            else
            {
                size_t bytes = 0;

                foreach (i, ref field; this.fields)
                {
                    bytes += field.iov_len;
                    if (bytes > n)
                    {
                        size_t d = bytes - n;
                        field.iov_base += field.iov_len - d;
                        field.iov_len  = d;
                        this.fields = this.fields[i .. $];
                        break;
                    }
                }
            }
            this.length -= n;
        }

        return this.length;
    }

    /***************************************************************************

        Copies the contents of this.fields into dst, appending them, and adjusts
        this instance to reference dst.

        Params:
            dst = destination buffer

    ***************************************************************************/

    void moveTo ( ref void[] dst )
    out
    {
        assert(this.length == dst.length);

        if (dst.length)
        {
            assert(this.fields.length == 1);
            with (this.fields[0]) assert(iov_base[0 .. iov_len] is dst);
        }
    }
    body
    {
        if (this.length)
        {
            if (dst)
            {
                dst.enableStomping();
                dst.length = this.length;
            }
            else
            {
                dst = new ubyte[this.length];
            }

            size_t start = 0;

            foreach (field; this.fields)
            {
                size_t end = start + field.iov_len;
                dst[start .. end] = field.iov_base[0 .. field.iov_len];
                start = end;
            }

            assert(start == this.length);

            this.fields = this.fields[0 .. 1];
            this.fields[0] = iovec(dst.ptr, this.length);
        }
        else if (dst)
        {
            dst.length = 0;
        }
    }

    /**************************************************************************/

    version ( UnitTest )
    {
        import ocean.core.Test: test;
        import ocean.transition;
        mixin TypeofThis;
    }

    unittest
    {
        void[] a = "Die".dup,
               b = "Katze".dup,
               c = "tritt".dup,
               d = "die".dup,
               e = "Treppe".dup,
               f = "krumm".dup;

        iovec[6] iovecs = void;

        This iov;

        void setup ( )
        {
            iovecs[0] = iovec(a.ptr, a.length);
            iovecs[1] = iovec(b.ptr, b.length);
            iovecs[2] = iovec(c.ptr, c.length);
            iovecs[3] = iovec(d.ptr, d.length);
            iovecs[4] = iovec(e.ptr, e.length);
            iovecs[5] = iovec(f.ptr, f.length);

            foreach (field; iov.fields = iovecs)
            {
                iov.length += field.iov_len;
            }
        }

        void[] iovField ( size_t i )
        {
            with (iov.fields[i]) return iov_base[0 .. iov_len];
        }

        setup();

        test(iov.length == 27);

        iov.advance(1);
        test(iov.length == 26);
        test(iov.fields.length == 6);

        test(iovField(0) == a[1 .. $]);
        test(iovField(1) == b);
        test(iovField(2) == c);
        test(iovField(3) == d);
        test(iovField(4) == e);
        test(iovField(5) == f);

        iov.advance(10);
        test(iov.length == 16);
        test(iov.fields.length == 4);
        test(iovField(0) == c[3 .. $]);
        test(iovField(1) == d);
        test(iovField(2) == e);
        test(iovField(3) == f);

        iov.advance(2);
        test(iov.length == 14);
        test(iov.fields.length == 3);
        test(iovField(0) == d);
        test(iovField(1) == e);
        test(iovField(2) == f);

        iov.advance(14);
        test(!iov.fields.length);
        test(!iov.length);

        setup();

        void[] buf;
        iov.moveTo(buf);
        test(buf == "DieKatzetrittdieTreppekrumm");
        test(iov.fields.length == 1);
        with (iov.fields[0]) test(iov_base[0 .. iov_len] is buf);
    }
}

