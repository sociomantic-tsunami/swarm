/*******************************************************************************

    Swarm record for stream serialization plus helper classes for streaming.

    Copyright: Copyright (c) 2015-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.util.RecordStream;

import ocean.transition;

/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.io.model.ISuspendable;
import ocean.io.serialize.SimpleStreamSerializer;
import ocean.io.Console : Cin, Cout;

version ( UnitTest )
{
    import ocean.core.Test;
}


/*******************************************************************************

    Record struct with de/serialize methods.

*******************************************************************************/

public struct Record
{
    import swarm.util.Hash;

    import ocean.core.Array : copy, find;
    import ocean.core.TypeConvert;
    import ocean.core.Enforce;

    import ocean.io.model.IConduit;
    import ocean.io.stream.Lines;
    import Base64 = ocean.util.encode.Base64;

    version ( UnitTest )
    {
        import ocean.core.Test;
    }


    /***************************************************************************

        Record key. 16-character hex-string or empty.

    ***************************************************************************/

    public ubyte[] key;


    /***************************************************************************

        Record value. Raw data.

    ***************************************************************************/

    public ubyte[] value;


    /***************************************************************************

        Key/value separator used for serialization. Must be a character which is
        not used by the base 64 encoding.

    ***************************************************************************/

    private static const Separator = ':';


    /***************************************************************************

        Check that the separator character is not used by the base 64 encoding.

    ***************************************************************************/

    unittest
    {
        auto decode_this = [Separator];
        ubyte[1] decode_buf;
        test!("==")(Base64.decode(decode_this, decode_buf), cast(ubyte[])[]);
    }


    /***************************************************************************

        Type of record. Covers the four possible cases of empty/non-empty key/
        value.

    ***************************************************************************/

    public enum Type
    {
        Empty,
        KeyOnly,
        ValueOnly,
        KeyValue
    }


    /***************************************************************************

        Serializes this record to the specified stream.

        Params:
            stream = stream to write to
            buf = working buffer required by the base 64 encoder

    ***************************************************************************/

    public void serialize ( OutputStream stream, ref mstring buf )
    {
        if ( this.key.length )
        {
            SimpleStreamSerializer.writeData(stream, this.key);
        }
        SimpleStreamSerializer.write(stream, Separator);

        buf.length = Base64.allocateEncodeSize(this.value);
        SimpleStreamSerializer.writeData(stream, Base64.encode(this.value, buf));
        SimpleStreamSerializer.write(stream, '\n');
    }


    /***************************************************************************

        Serializes this record from the specified stream.

        Params:
            stream = stream to read from
            buf = working buffer required to read record value into before base
                64 decoding

        Throws:
            EofException upon encountering the end of the input stream

    ***************************************************************************/

    public void deserialize ( InputStream stream, ref mstring buf )
    {
        // Read the whole line into the working buffer.
        buf.length = 0;
        readUntil(stream, '\n', buf);

        // Extract the key and value from the line
        splitRecord(cast(ubyte[])buf, this.key, this.value);
    }


    /***************************************************************************

        Returns:
            the type of this record (see Type enum)

    ***************************************************************************/

    public Type type ( )
    {
        if ( this.key.length )
        {
            return this.value.length ? Type.KeyValue : Type.ValueOnly;
        }
        else
        {
            return this.value.length ? Type.ValueOnly : Type.Empty;
        }
    }


    /***************************************************************************

        Returns:
            the record key, converted to a hash

        Throws:
            Exception if this.key does not contain a valid 16-digit hexadecimal
            string

    ***************************************************************************/

    public hash_t hash ( )
    {
        enforce(isHash(castFrom!(ubyte[]).to!(mstring)(this.key)));

        return straightToHash(castFrom!(ubyte[]).to!(mstring)(this.key));
    }


    /***************************************************************************

        Sets this record's key to a hex-string equal to the provided hash.

        Params:
            h = the hash to generate the record key from

    ***************************************************************************/

    public void hash ( hash_t h )
    {
        this.key.length = HashDigits;
        intToHex(h, cast(char[])this.key);
    }


    /***************************************************************************

        Helper function to read from a stream into the provided buffer until the
        specified separator character is encountered. The separator is *not*
        appended to the output buffer.

        Template params:
            C = output buffer array element type (must be a one byte type)

        Params:
            stream = stream to read from
            sep = separator to read until
            dst = buffer to write read data into

        TODO: this function could be more efficiently implemented by reading
        larger chunks from the stream, then splitting them by \n. However, this
        would make the module more complicated and, until we have evidence of it
        being necessary, I'd prefer to keep the code simple.

    ***************************************************************************/

    private static void readUntil ( C )
        ( InputStream stream, char sep, ref C[] dst )
    {
        static assert(C.sizeof == char.sizeof);

        char c;
        SimpleStreamSerializer.read(stream, c);

        while ( c != sep )
        {
            dst ~= cast(C)c;
            SimpleStreamSerializer.read(stream, c);
        }
    }


    /***************************************************************************

        Extracts a record from the given input data, copying the extracted key
        and value into the provided buffers. The function detects input lines of
        two formats, as follows:
            1. Valid pipe-formatted records, consisting of: a key (0 or more
               bytes), followed a : character, followed by a value (0 or more
               valid base-64 characters).
            2. Raw data.

        Type 1. lines will be separated into key and value and the value will be
        base-64 decoded.

        Type 2. lines will be treated as values (no key) and copied directly as
        raw data.

        Params:
            input = line of input to split
            key = output buffer to receive record key
            value = output buffer to receive record value

    ***************************************************************************/

    private static void splitRecord ( ubyte[] input, ref ubyte[] key,
        ref ubyte[] value )
    {
        bool split ( ubyte[] line )
        {
            // Find the separator
            auto sep = line.find(cast(ubyte)Separator);
            if ( sep == line.length )
                return false;

            // If another separator is found, the line is invalid
            auto head = line[0..sep];
            ubyte[] tail;
            if ( sep < line.length - 1 )
            {
                tail = line[sep + 1..$];
                auto sep2 = tail.find(cast(ubyte)Separator);
                if ( sep2 < tail.length )
                    return false;
            }

            // The head (before the separator) is expected to be the record key
            // and must either be empty or be a 16-character hex-string.
            if ( head.length && !isHash(castFrom!(ubyte[]).to!(mstring)(head)) )
                return false;

            // The tail (after the separator) is expected to be the record value
            // and must either be empty or only contain valid base-64
            // characters. Try decoding it into value
            value.length = tail.length;
            if ( tail.length )
            {
                value = Base64.decode(cast(mstring)tail, value);
                if ( !value.length )
                    return false;
            }

            // Value was valid, so copy head into key
            key.copy(head);
            return true;
        }

        // Attempt to handle this line as a base-64 record. If this fails, treat
        // the line as a raw data record (value only).
        if ( !split(input) )
        {
            key.length = 0;
            value.copy(input);
        }
    }

    unittest
    {
        // Helper function to check the output of splitRecord() for a raw,
        // non-pipe-formatted input string
        void testSplitRaw ( cstring input )
        {
            ubyte[] key, value;
            splitRecord(cast(ubyte[])input, key, value);
            test!("==")(key.length, 0);
            test!("==")(value, cast(ubyte[])input);
        }

        // Helper function to check the output of splitRecord() for a properly
        // pipe-formatted input string
        void testSplitPiped ( cstring key, cstring value )
        {
            auto base64_value = Base64.encode(cast(ubyte[])value);
            auto input = key ~ ":" ~ base64_value;

            ubyte[] split_key, split_value;
            splitRecord(cast(ubyte[])input, split_key, split_value);
            test!("==")(split_key, cast(ubyte[])key);
            test!("==")(split_value, cast(ubyte[])value);
        }

        // A test raw record
        testSplitRaw("this is totally not base-64 encoded");

        // An ok looking record with multiple separators
        testSplitRaw("BBBB:BBBB:");

        // A record with an invalid (too short) key
        testSplitRaw("bad:BBBB");

        // A record with an invalid (too long) key
        testSplitRaw("badbadbadbadbadbadbadbad:BBBB");

        // A record with an invalid (non-hex) key
        testSplitRaw("thisistotaljunk:BBBB");

        // A valid empty record
        testSplitPiped("", "");

        // A valid record with key and value
        testSplitPiped("0123456789abcdef", "this is my value");

        // A valid record with key only
        testSplitPiped("0123456789abcdef", "");

        // A valid record with value only
        testSplitPiped("", "this is my value");
    }
}


/*******************************************************************************

    Suspendable stream class which reads Records from stdin.

*******************************************************************************/

public class StdinRecordStream : ISuspendable
{
    import ocean.core.MessageFiber;

    /***************************************************************************

        Fiber which reads from stdin.

    ***************************************************************************/

    private MessageFiber fiber;

    /***************************************************************************

        Token used to suspend/resume fiber.

    ***************************************************************************/

    private MessageFiber.Token token = MessageFiber.Token("suspendable");

    /***************************************************************************

        Per-record output delegate.

    ***************************************************************************/

    private alias bool delegate ( Record ) OutputDg;

    /// ditto
    private OutputDg output_dg;

    /***************************************************************************

        Flag which is set to true if the stream ends cleanly.

    ***************************************************************************/

    private bool end_of_stream;

    /***************************************************************************

        Buffer used for deserializing records.

    ***************************************************************************/

    private char[] deserialize_buf;

    /***************************************************************************

        Record read from stream.

    ***************************************************************************/

    private Record record;

    /***************************************************************************

        Constructor.

        Params:
            output_dg = delegate to receive records as they are read from stdin

    ***************************************************************************/

    public this ( OutputDg output_dg )
    {
        const fiber_stack_size = 256 * 1024;
        this.fiber = new MessageFiber(&this.fiberMethod, fiber_stack_size);
        this.output_dg = output_dg;
    }

    /***************************************************************************

        Starts handling the stream.

        Returns:
            true if the stream ended cleanly, false if an error occurred

    ***************************************************************************/

    public bool process ( )
    {
        this.fiber.start();
        return this.end_of_stream;
    }

    /***************************************************************************

        Requests that further processing be temporarily suspended, until
        resume() is called.

    ***************************************************************************/

    override public void suspend ( )
    {
        this.fiber.suspend(token);
    }

    /***************************************************************************

        Requests that processing be resumed.

    ***************************************************************************/

    override public void resume ( )
    {
        this.fiber.resume(token);
    }

    /***************************************************************************

        Returns:
            true if the process is suspended

    ***************************************************************************/

    override public bool suspended ( )
    {
        return !this.fiber.running;
    }

    /***************************************************************************

        Fiber method which reads records from stdin and forwards them to the
        provided output delegate.

    ***************************************************************************/

    private void fiberMethod ( )
    {
        while (true)
        {
            try
            {
                this.record.deserialize(Cin.stream, this.deserialize_buf);
            }
            catch ( EofException e )
            {
                // An I/O exception (EOF) is expected when reading a key
                this.end_of_stream = true;
                break;
            }

            if ( !this.output_dg(this.record) )
                // An error occurred while handling the received record.
                break;
        }
    }
}

