/*******************************************************************************

    Helper class to read and store in memory a null-terminated list of strings
    using a FiberSelectReader.

    copyright:      Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.protocol.StringListReader;



/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.transition;

import ocean.util.container.ConcatBuffer;

import swarm.protocol.FiberSelectReader;



/*******************************************************************************

    Helper class to read a null-terminated list of strings using a
    FiberSelectReader. The received strings are stored in a ConcatBuffer held in
    the class, making it memory-leak proof.

*******************************************************************************/

public class StringListReader
{
    /***************************************************************************

        Select reader.

        Note that the select reader instance is not const, as it is occasionally
        useful to be able to change the event after construction. An example of
        this use case would be when a string list reader instance is created for
        use with a request, but then, some time later, needs to be re-used for a
        different request - necessitating a select reader switch.

    ***************************************************************************/

    public FiberSelectReader reader;


    /***************************************************************************

        Temporary buffer to store strings as they are read in.

        Note that the buffer is not const, as it is occasionally useful to be
        able to change the buffer after construction. An example of this use
        case would be when a string list reader instance is created for use with
        a request, but then, some time later, needs to be re-used for a
        different request - necessitating a buffer switch.

    ***************************************************************************/

    public mstring* buffer;


    /***************************************************************************

        Buffer to store strings.

        TODO: this buffer could also, theoretically, be acquired from a pool of
        shared resources.

    ***************************************************************************/

    private ConcatBuffer!(char) strings_buffer;


    /***************************************************************************

        Strings list (slices into the strings_buffer).

        TODO: this buffer could also, theoretically, be acquired from a pool of
        shared resources.

    ***************************************************************************/

    private cstring[] strings;


    /***************************************************************************

        Constructor.

        Params:
            reader = fiber select reader to read from
            buffer = working buffer used to read in strings

    ***************************************************************************/

    public this ( FiberSelectReader reader, ref mstring buffer )
    {
        this.reinitialise(reader, &buffer);
        this.strings_buffer = new ConcatBuffer!(char);
    }


    /***************************************************************************

        Reinitialiser. Called when the string list reader is re-used by a
        different request handler.

        Params:
            reader = fiber select reader to read from
            buffer = working buffer used to read in strings

    ***************************************************************************/

    public void reinitialise ( FiberSelectReader reader, mstring* buffer )
    {
        this.buffer = buffer;
        this.reader = reader;
    }


    /***************************************************************************

        Reads a series of strings from the select reader, ending when a string
        of 0 length is received.

        Aliased as opCall.

        Returns:
            list of strings read

    ***************************************************************************/

    public cstring[] read ( )
    {
        this.strings.length = 0;
        enableStomping(this.strings);
        this.strings_buffer.clear;

        // Read strings
        do
        {
            this.buffer.length = 0;
            enableStomping(*this.buffer);
            this.reader.readArray(*this.buffer);

            if ( this.buffer.length > 0 )
            {
                this.strings ~= this.strings_buffer.add(*this.buffer);
            }
        }
        while ( this.buffer.length > 0 );

        return this.strings;
    }

    public alias read opCall;
}
