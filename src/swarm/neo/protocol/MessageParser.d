/*******************************************************************************

    Helper struct for parsing fields serialized in a message body.

    Copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.protocol.MessageParser;

/// ditto
struct MessageParser
{
    import swarm.neo.protocol.ProtocolError;

    import ocean.core.Traits: hasIndirections;

    import ocean.transition;

    debug (MessageProtocol) import ocean.io.Stdout_tango;

    /***************************************************************************

        Exception instance thrown on protocol error. (Must be set externaly.)

    ***************************************************************************/

    public ProtocolError e;

    /***************************************************************************

		This is needed for a `parseBody()` parameter, `Const!(void)[]` would
		break the automatic function template instantiation in D1, and
		`in void[]`, which implies `const(void[])`, cannot be used there.

    ***************************************************************************/

	version (D_Version2)
	{
		mixin("alias const(void)[] ConstVoidArray;");
	}
	else
	{
		alias void[] ConstVoidArray;
	}

    /***************************************************************************

        Parses the message body, which is expected to consist of the raw data
        for fields.

        Each element of fields must be either
          - a value type or
          - a dynamic array of a value type.

        There must be at least one field.
        Dynamic array fields will slice msg_body. The elements in the output
        array may be misaligned in memory according to the element type.

        All sorts of value types are supported (structs/unions, static arrays,
        enums/typedefs etc.).

        In msg_body the fields are sequential without padding. Each dynamic
        array is preceded with a size_t field containing the array length
        (number of elements).
        As an exception, if there is only one field, and it is a dynamic array,
        the array length is not included. The message body then consists of that
        array. A single void[] field simply obtains the full raw message body.

        Params:
            msg_body = the message body to parse
            fields   = output variables for the message fields, in that order

        Throws:
            ProtocolError on parse error. All parse errors in this method are
            caused by msg_body.length not matching the expected length according
            to fields, including the (supposed) lengths of all dynamic array
            fields.

    ***************************************************************************/

    public void parseBody ( Fields ... ) ( ConstVoidArray msg_body, out Fields fields )
    {
        debug (MessageProtocol)
            Stdout.formatln("Parse message body {} {:X2}",
                            Fields.stringof, msg_body);

        // The single-array body optimisation is disabled until we have a
        // serialiser that supports it automatically. TupleToSlices could do it
        // if it would add array lengths internally.

        version (none)
        {
            static if (Fields.length == 1 && is(Fields[0] Element == Element[]))
            {
                fields[0] = this.getSingleArrayBody!(Element)(msg_body);
            }
            // else do the following foreach loop
        }

        foreach (ref field; fields)
        {
            alias typeof(field) Field;

            static if (is(Field Element == Element[]))
            {
                field = this.getArray!(Element)(msg_body);
            }
            else
            {
                field = *this.getValue!(Field)(msg_body);
            }
        }

        this.e.enforceFmt(!msg_body.length, "message too long: {} extra byte(s)", msg_body.length);
    }

    /***************************************************************************

        Parses one filed in msg_body_rest, expecting it to be the raw data of
        a value of type T.

        Sets msg_body to start with the next field on success.

        Template Params:
            T = the field type (must be a value type).

        Params:
            msg_body_rest = the message body to parse

        Returns:
            the resulting value (referencing the initial beginning of
            msg_body_rest)

        Throws:
            ProtocolError if msg_body_rest is too short.

    ***************************************************************************/

    public Const!(T)* getValue ( T ) ( ref Const!(void)[] msg_body_rest )
    {
        static assert(!hasIndirections!(T));
        this.e.enforceFmt(msg_body_rest.length >= T.sizeof,
                     "message too short: {} byte(s) missing",
                     T.sizeof - msg_body_rest.length);
        scope (exit) msg_body_rest = msg_body_rest[T.sizeof .. $];
        return cast(Const!(T)*)msg_body_rest.ptr;
    }

    /***************************************************************************

        Parses msg_body which consists of a single dynamic array. msg_body is
        expected to solely contain the array elements (not length information).

        This is exactly like cast(T[])msg_body except that
          - ProtocolError is thrown on error and
          - T is verified at compile time to be a value type
        so for T.sizeof == 1 using this method is not required
        (especially for T == void).

        Template Params:
            T = the array element type (must be a value type)

        Params:
            msg_body = the message body to parse

        Returns:
            the resulting array, i.e. cast(T[])msg_body

        Throws:
            ProtocolError if msg_body.length is not a multiple of T.sizeof.

    ***************************************************************************/

    // Disabled for now, see parseBody().

    version (none) private Const!(T)[] getSingleArrayBody ( T ) ( in void[] msg_body )
    {
        static assert(!hasIndirections!(T));

        static if (T.sizeof != 1)
            this.e.enforceFmt(!(msg_body.length % T.sizeof),
                "the length {} of an array message is not a multiple of the " ~
                "array element length {}", msg_body.length, T.sizeof);

        return cast(Const!(T)[])msg_body;
    }

    /***************************************************************************

        Parses one filed in msg_body_rest, expecting it to be a dynamic array
        where
          - msg_body_rest[0 .. size_t.sizeof] is the data of a "size_t n" value,
            the number of elements the array, and
          - msg_body_rest[size_t.sizeof .. n * T.sizeof] the array elements.

        Sets msg_body to start with the next field on success.

        Template Params:
            T = the array element type (must be a value type).

        Params:
            msg_body_rest = the message body to parse

        Returns:
            the resulting array (referencing the initial beginning of
            msg_body_rest)

        Throws:
            ProtocolError if msg_body_rest is too short.

    ***************************************************************************/

    public Const!(T)[] getArray ( T ) ( ref Const!(void)[] msg_body_rest )
    {
        debug (MessageProtocol)
            Stdout.formatln("\tgetArray {} {:X2}", T.stringof, msg_body_rest);

        static assert(!hasIndirections!(T));
        auto n_bytes = *this.getValue!(size_t)(msg_body_rest) * T.sizeof;

        debug (MessageProtocol)
            Stdout.formatln("\tn_bytes = 0x{:X} ({}), content = {:X2}",
                            n_bytes, n_bytes, msg_body_rest);

        this.e.enforceFmt(msg_body_rest.length >= n_bytes,
                                   "message too short: {} byte(s) missing",
                                   n_bytes - msg_body_rest.length);
        scope (exit) msg_body_rest = msg_body_rest[n_bytes .. $];
        return cast(Const!(T)[])msg_body_rest[0 .. n_bytes];
    }

}
