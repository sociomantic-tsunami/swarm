/*******************************************************************************

    Fiber/coroutine based non-blocking input class

    Non-blocking input select client using a fiber/coroutine to suspend
    operation while waiting for the read event and resume on that event.

    Provides methods to:
        * deserialize simple types
        * deserialize arrays (the length is read first, as a size_t, then the
            content)

    copyright:      Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.protocol.FiberSelectReader;



/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.transition;

import ocean.core.Array;

import Ocean = ocean.io.select.protocol.fiber.FiberSelectReader;

import ocean.io.select.protocol.fiber.model.IFiberSelectProtocol;

import ocean.io.select.EpollSelectDispatcher;

import ocean.core.Traits;

import ocean.math.Math : min, max;



public class FiberSelectReader : Ocean.FiberSelectReader
{
    /***************************************************************************

        Constructor.

        error_e and warning_e may be the same object if distinguishing between
        error and warning is not required.

        Params:
            input       = input device
            fiber       = input reading fiber
            warning_e   = exception to throw on end-of-flow condition or if the
                          remote hung up
            error_e     = exception to throw on I/O error
            buffer_size = input buffer size

    ***************************************************************************/

    public this ( IInputDevice input, SelectFiber fiber,
        IOWarning warning_e, IOError error_e,
        size_t buffer_size = this.default_buffer_size )
    {
        super(input, fiber, warning_e, error_e, buffer_size);
    }


    /***************************************************************************

        Constructor. Re-uses the same output device, fiber and exception
        instances contained in the provided IFiberSelectProtocol.

        Params:
            socket      = socket to read from
            buffer_size = input buffer size

    ***************************************************************************/

    public this ( IFiberSelectProtocol socket,
           size_t buffer_size = this.default_buffer_size )
    {
        super(socket, buffer_size);
    }


    /***************************************************************************

        Reads a value of the specified type from the input conduit. Whenever no
        data is available from the input conduit, the input reading fiber is
        suspended and continues reading on resume.

        Template params:
            T = type of value to read

        Params:
            value = value to read

        Returns:
            this instance

        Throws:
            IOException on end-of-flow condition:
                - IOWarning if neither error is reported by errno nor socket
                  error
                - IOError if an error is reported by errno or socket error

    ***************************************************************************/

    version ( UseOceanRead ) {} else
    public typeof (this) read ( T ) ( ref T value )
    {
        auto expected_bytes = T.sizeof;

        size_t received_bytes;

        size_t consumer ( void[] data )
        {
            return this.readConsumer(data, expected_bytes, received_bytes, &value);
        }

        super.readConsume(&consumer);

        return this;
    }


    /***************************************************************************

        Reads an array of values of the specified type from the input conduit.
        The array's length is read from the conduit first, as a size_t, followed
        by its elements. Whenever no data is available from the input conduit,
        the input reading fiber is suspended and continues reading on resume.

        Template params:
            SizeT = type of the size value, defaults to size_t
            T = type of array element to read

        Params:
            value = array to read

        Returns:
            this instance

        Throws:
            IOException on end-of-flow condition:
                - IOWarning if neither error is reported by errno nor socket
                  error
                - IOError if an error is reported by errno or socket error

    ***************************************************************************/

    public typeof (this) readArray ( SizeT = size_t, T ) ( ref T[] array )
    {
        static assert ( !isArrayType!(T), "Reading multi-dimensional arrays not currently supported");

        // Read array length
        SizeT array_len;
        this.read(array_len);

        this.readArray(array, array_len);

        return this;
    }


    /***************************************************************************

        Reads an array of values of the specified type from the input conduit.
        The array's length is read from the conduit first, as a size_t. If the
        size of the complete array (in terms of the number of bytes to be read)
        is smaller than the specified maximum, then the array data is read from
        the socket and copied into the provided buffer. Otherwise, the data is
        read but is not loaded into the buffer. Whenever no data is available
        from the input conduit, the input reading fiber is suspended and
        continues reading on resume.

        Template params:
            SizeT = type of the size value, defaults to size_t
            T = type of array element to read

        Params:
            array = array to read
            max_array_size = maximum size of array to read (in bytes). If the
                actual array exceeds this size, it will be read but discarded

        Returns:
            true if the array was loaded, false if it was read but discarded

        Throws:
            IOException on end-of-flow condition:
                - IOWarning if neither error is reported by errno nor socket
                  error
                - IOError if an error is reported by errno or socket error

    ***************************************************************************/

    public bool readArrayLimit ( SizeT = size_t, T ) ( ref T[] array,
        size_t max_array_size )
    {
        static assert(!isArrayType!(T), "Reading multi-dimensional arrays not currently supported");

        // Read array length
        SizeT array_len;
        this.read(array_len);
        auto array_size = array_len * T.sizeof;

        if ( array_size > max_array_size )
        {
            this.skipBytes(array_size);
            return false;
        }
        else
        {
            this.readArray(array, array_len);
            return true;
        }
    }


    /***************************************************************************

        Reads an array of values of the specified type from the input conduit,
        reading the specified number of elements. Whenever no data is available
        from the input conduit, the input reading fiber is suspended and
        continues reading on resume.

        Template params:
            SizeT = type of the size value, defaults to size_t
            T = type of array element to read

        Params:
            array = array to read
            array_len = number of array elements to read (resulting length of
                the array)

        Returns:
            this instance

        Throws:
            IOException on end-of-flow condition:
                - IOWarning if neither error is reported by errno nor socket
                  error
                - IOError if an error is reported by errno or socket error

    ***************************************************************************/

    private void readArray ( SizeT = size_t, T ) ( ref T[] array,
        SizeT array_len )
    {
        enableStomping(array);
        array.length = max(0, array_len); // to handle negative input as well
        enableStomping(array);

        if ( array_len > 0 )
        {
            version ( UseOceanRead )
            {
                this.readRaw((cast(ubyte*)array.ptr)[0 .. array_len * T.sizeof]);
            }
            else
            {
                auto expected_bytes = array_len * T.sizeof;
                size_t received_bytes;

                size_t consumer ( void[] data )
                {
                    return this.readConsumer(data, expected_bytes, received_bytes, array.ptr);
                }

                super.readConsume(&consumer);
            }
        }
    }


    /***************************************************************************

        Reads a value of the specified type from the input conduit, but does
        nothing with the value, simply discards it. Whenever no data is
        available from the input conduit, the input reading fiber is suspended
        and continues reading on resume.

        Note: it is sometimes useful to be able to skip a value without reading
        it into memory, for example in situations where the a request has been
        made but the response is no longer relevant.

        Template params:
            T = type of value to read

        Returns:
            this instance

        Throws:
            IOException on end-of-flow condition:
                - IOWarning if neither error is reported by errno nor socket
                  error
                - IOError if an error is reported by errno or socket error

    ***************************************************************************/

    public typeof (this) skip ( T ) ( )
    {
        auto expected_bytes = T.sizeof;

        size_t received_bytes;

        size_t consumer ( void[] data )
        {
            return this.skipConsumer(data, expected_bytes, received_bytes);
        }

        super.readConsume(&consumer);

        return this;
    }


    /***************************************************************************

        Reads an array of values of the specified type from the input conduit.
        The array's length is read from the conduit first, as a size_t, followed
        by its elements. Nothing is done with the elements, they are simply
        discarded. Whenever no data is available from the input conduit, the
        input reading fiber is suspended and continues reading on resume.

        Note: it is sometimes useful to be able to skip a value without reading
        it into memory, for example in situations where the a request has been
        made but the response is no longer relevant.

        Template params:
            T = type of value to read
            SizeT = type of the size value, defaults to size_t

        Returns:
            this instance

        Throws:
            IOException on end-of-flow condition:
                - IOWarning if neither error is reported by errno nor socket
                  error
                - IOError if an error is reported by errno or socket error

    ***************************************************************************/

    public typeof (this) skipArray ( T, SizeT = size_t ) ( )
    {
        static assert ( !isArrayType!(T), "Skipping multi-dimensional arrays not currently supported");

        // Read array length
        SizeT array_len;
        this.read(array_len);

        this.skipBytes(array_len * T.sizeof);

        return this;
    }


    /***************************************************************************

        Reads the specified number of bytes from the input conduit. The data is
        read but simply discarded. Whenever no data is available from the input
        conduit, the input reading fiber is suspended and continues reading on
        resume.

        Params:
            bytes = number of bytes to read and discard

        Throws:
            IOException on end-of-flow condition:
                - IOWarning if neither error is reported by errno nor socket
                  error
                - IOError if an error is reported by errno or socket error

    ***************************************************************************/

    private void skipBytes ( size_t bytes )
    {
        if ( bytes > 0 )
        {
            size_t received_bytes;

            size_t consumer ( void[] data )
            {
                return this.skipConsumer(data, bytes, received_bytes);
            }

            super.readConsume(&consumer);
        }
    }


    /**************************************************************************

        Consumer callback used by read() and readArray() methods above. Consumes
        data from the provided buffer, copies consumed data to the specified
        destination, and updates the count of bytes received.

        Params:
            data = new data received
            expected_bytes = total number of bytes to be read
            received_bytes = bytes received so far, updated with length of new
                data
            dst = pointer to destination for data

        Returns:
            number of bytes remaining to be read

     **************************************************************************/

    version ( UseOceanRead ) {}  else
    private size_t readConsumer ( void[] data, size_t expected_bytes,
        ref size_t received_bytes, void* dst )
    {
        auto remaining_bytes = expected_bytes - received_bytes;
        auto consumed_bytes = min(remaining_bytes, data.length);

        void* ptr = dst + received_bytes;
        ptr[0..consumed_bytes] = data[0..consumed_bytes];

        received_bytes += consumed_bytes;

        return remaining_bytes;
    }


    /**************************************************************************

        Consumer callback used by skip() and skipArray() methods above. Consumes
        data from the provided buffer, discards it, and updates the count of
        bytes received.

        Params:
            data = new data received
            expected_bytes = total number of bytes to be read
            received_bytes = bytes received so far, updated with length of new
                data

        Returns:
            number of bytes remaining to be read

     **************************************************************************/

    private size_t skipConsumer ( void[] data, size_t expected_bytes,
        ref size_t received_bytes )
    {
        auto remaining_bytes = expected_bytes - received_bytes;
        auto consumed_bytes = min(remaining_bytes, data.length);

        received_bytes += consumed_bytes;

        return remaining_bytes;
    }
}


/*******************************************************************************

    Simple unittest to check that template methods compile

*******************************************************************************/

unittest
{
    static assert(is(typeof(
        { FiberSelectReader reader; int x; reader.read(x); })));
    static assert(is(typeof(
        { FiberSelectReader reader; int[] a; reader.readArray(a); })));
    static assert(is(typeof(
        { FiberSelectReader reader; int[] a; reader.readArrayLimit(a, 1); })));
    static assert(is(typeof(
        { FiberSelectReader reader; int[] a; reader.readArray(a, 1); })));
    static assert(is(typeof(
        { FiberSelectReader reader; reader.skip!(int)(); })));
    static assert(is(typeof(
        { FiberSelectReader reader; reader.skipArray!(int)(); })));
}

