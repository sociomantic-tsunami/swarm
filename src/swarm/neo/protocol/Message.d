/*******************************************************************************

    Message format definition.

    A message consists of a MessageHeader header, followed immediately by
    header.body_length bytes of the message body. header.type is intentionally
    the first byte of the message.

    MessageHeader is a packed struct so that one can rely on the offsets of its
    fields and access them in raw data without actually using the struct if this
    is more convenient, for example to peek the message type.

    The expected length of the message body depends on the message type:
     - MessageType.Request: The message body is expected to start with a request
       id so its length must be at least RequestId.sizeof.
     - MessageType.Authentication: The message body length must to be at most
       MessageHeader.max_auth_body_length.

    MessageHeader.parity is a simple data integrity check. It must be the XOR
    of all other bytes in the header; the XOR of all header bytes is then 0.
    It is meant to be an error reporting and debugging aid. Its error detection
    strength is not very high so it cannot not replace the data integrity check
    of the network protocol, and the plausibility of the other header fields
    must always be verified.

    Copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.protocol.Message;

/******************************************************************************/

enum MessageType: ubyte
{
    /***************************************************************************

        Placeholder for bug and error detection.

    ***************************************************************************/

    Invalid = 0,

    /***************************************************************************

        Used for request messages, the standard message type. The message body
        is expected to start with a request id so its length must be
        >= RequestId.sizeof.

    ***************************************************************************/

    Request,

    /***************************************************************************

        Used for messages exchanged during the authentication procedure. The
        length of the message body is expected to be <= max_auth_body_length.

    ***************************************************************************/

    Authentication,
}

/*******************************************************************************

    Message header definition. This is a packed struct so that one can rely on
    the offsets of its fields and access them in raw data without actually using
    the struct if this is more convenient, for example to peek the message type.

    Because it is a packed struct, fields can be misaligned corresponding to
    their types, so be careful when modifying fields in-place or if adding
    reference fields in the future, the latter may be invisible to the GC.

*******************************************************************************/

align(1) struct MessageHeader
{
    import swarm.neo.protocol.ProtocolError;

    align(1):

    /***************************************************************************

        The type of this message.

    ***************************************************************************/

    MessageType type;

    /***************************************************************************

        The length of the message body. The total length of the message is
        (*this).sizeof + this.body_length.

    ***************************************************************************/

    ulong body_length;

    /***************************************************************************

        This field should be set up so that the XOR of all bytes of this
        instance is 0, i.e. it is the XOR of all other bytes of this instance.

    ***************************************************************************/

    ubyte parity;

    /***************************************************************************

        The maximum allowed message body length if this.type is
        type.Authentication. (This is an arbitrarily chosen sanity check value,
        which is just used to catch the case of malicious or junk data being
        sent to the node.)

    ***************************************************************************/

    const max_auth_body_length = 999;

    /***************************************************************************

        Sets up this.parity properly.

        Returns:
            this.parity

        Out:
            this.parity is set up properly.

    ***************************************************************************/

    ubyte setParity ( )
    out
    {
        assert(!this.total_parity);
    }
    body
    {
        return this.parity = this.calcParity();
    }

    /***************************************************************************

        Calculates the XOR of all bytes of this instance. If this.parity is set
        up properly and data are valid then the result is 0. (Note that the
        opposite is not necessarily true.)

    ***************************************************************************/

    ubyte total_parity ( ) /* d1to2fix_inject: const */
    {
        return this.calcParity(this.parity);
    }

    /***************************************************************************

        Calculates the XOR of parity_in and all bytes of this instance except
        this.parity.

        Params:
           parity_in = start parity

        Returns:
            the XOR of parity_in and all bytes of this instance except
            this.parity.

    ***************************************************************************/

    ubyte calcParity ( ubyte parity_in = 0 ) /* d1to2fix_inject: const */
    {
        ulong a = this.body_length,
              b = cast(uint)  (a ^ (a >>> (uint.sizeof   * 8))),
              c = cast(ushort)(b ^ (b >>> (ushort.sizeof * 8)));

        return cast(ubyte)(c ^ (c >>> (ubyte.sizeof  * 8))) ^ this.type ^ parity_in;
    }

    /***************************************************************************

        Validates this instance by verifying that
          - the parity is correct,
          - the type is one of the `MessageType` values,
          - the length of the message body is in the range allowed for the type.

        Params:
            e = the exception to throw if the validation fails

        Throws:
            ProtocolError if the validation failed.

    ***************************************************************************/

    public void validate ( ProtocolError e ) /* d1to2fix_inject: const */
    {
        e.enforce(!this.total_parity, "message header data parity fault");

        switch (this.type)
        {
            case type.Request:
                e.enforceFmt(this.body_length >= RequestId.sizeof, "Request " ~
                    "message body too short to contain a request id (length " ~
                    "= {}, minimum is {})", this.body_length, RequestId.sizeof);
                break;
            case type.Authentication:
                e.enforceFmt(this.body_length <= this.max_auth_body_length,
                    "Authentication message body too long (length = {}, " ~
                    "maximum is {})", this.body_length, this.max_auth_body_length);
                break;
            default:
                throw e.setFmt("invalid message type {}", this.type);
        }
    }

    /***************************************************************************

        Make sure there are no padding bytes in this struct.

    ***************************************************************************/

    import swarm.neo.util.FieldSizeSum;

    static assert(FieldSizeSum!(typeof(*this)) == typeof(*this).sizeof);
}

/*******************************************************************************

    Request id type definition.

*******************************************************************************/

alias ulong RequestId;
