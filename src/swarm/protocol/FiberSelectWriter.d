/*******************************************************************************

    Fiber/coroutine based non-blocking output class

    Non-blocking output select client using a fiber/coroutine to suspend
    operation while waiting for the write event and resume on that event.

    Provides methods to:
        * serialize simple types
        * serialize arrays (the length is written first, as a size_t, then the
            content)

    copyright:      Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.protocol.FiberSelectWriter;



/*******************************************************************************

    Imports

*******************************************************************************/

import Ocean = ocean.io.select.protocol.fiber.BufferedFiberSelectWriter;
import ocean.io.select.protocol.fiber.model.IFiberSelectProtocol;

import ocean.io.select.EpollSelectDispatcher;

import ocean.core.Traits;

import ocean.math.Math : min;

import ocean.core.Array : copy;



public class FiberSelectWriter : Ocean.BufferedFiberSelectWriter
{
    /***************************************************************************

        Constructor

        Params:
            output = output device
            fiber = output writing fiber
            warning_e = exception to throw on end-of-flow condition or if the
                remote hung up
            error_e = exception to throw on I/O error
            size = buffer size

        In:
            The buffer size must not be 0.

    ***************************************************************************/

    public this ( IOutputDevice output, SelectFiber fiber,
        IOWarning warning_e, IOError error_e,
        size_t size = default_buffer_size )
    in
    {
        assert (size, "zero input buffer size specified");
    }
    body
    {
        super(output, fiber, warning_e, error_e, size);
    }


    /***************************************************************************

        Constructor. Re-uses the same output device, fiber and exception
        instances contained in the provided IFiberSelectProtocol.

        Params:
            socket  = socket to write to

    ***************************************************************************/

    public this ( IFiberSelectProtocol socket )
    {
        super(socket);
    }


    /***************************************************************************

        Writes a value of the specified type to the output conduit. Whenever the
        output conduit is not ready for writing, the output writing fiber is
        suspended and continues writing on resume.

        Template params:
            T = type of value to write

        Params:
            value = value to write

        Returns:
            this instance

    ***************************************************************************/

    public typeof(this) write ( T ) ( T value )
    {
        super.send((cast(void*)&value)[0..T.sizeof]);
        return this;
    }

    unittest
    {
        void instantiate ()
        {
            FiberSelectWriter writer;
            writer.write(42);
        }
    }

    /***************************************************************************

        Writes an array of values of the specified type to the output conduit.
        The array's length is written to the conduit first, as a size_t,
        followed by its elements. Whenever the output conduit is not ready for
        writing, the output writing fiber is suspended and continues writing on
        resume.

        Template params:
            T = type of array element to write

        Params:
            value = array to write

        Returns:
            this instance

    ***************************************************************************/

    public typeof(this) writeArray ( SizeT = size_t, T ) ( T[] array )
    {
        static assert ( !isArrayType!(T), "Writing multi-dimensional arrays not currently supported");

        this.write(cast(SizeT)array.length);

        super.send((cast(void*)array.ptr)[0 .. array.length * T.sizeof]);

        return this;
    }

    unittest
    {
        void instantiate ()
        {
            FiberSelectWriter writer;
            writer.writeArray( [ 1, 2, 3 ] );
        }
    }
}


