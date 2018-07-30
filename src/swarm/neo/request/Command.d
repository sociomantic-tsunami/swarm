/*******************************************************************************

    Request command format and global response code definition.

    Copyright: Copyright (c) 2016-2017 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.neo.request.Command;

/*******************************************************************************

    Struct defining the information transmitted from client -> node to start a
    request.

*******************************************************************************/

public struct Command
{
    alias ubyte Code;
    alias ubyte Version;

    Code code;
    Version ver;

    /***************************************************************************

        Make sure there are no padding bytes in this struct.

    ***************************************************************************/

    import swarm.neo.util.FieldSizeSum;

    static assert(FieldSizeSum!(typeof(*this)) == typeof(*this).sizeof);
}

/*******************************************************************************

    Status code alias.

*******************************************************************************/

public alias byte StatusCode;

/*******************************************************************************

    Enum defining request supported status codes transmitted from the node ->
    client, in response to a request.

*******************************************************************************/

public enum SupportedStatus : StatusCode
{
    /// Both request code specified in the transmitted Command struct and the
    /// associated request version are supported and the request will start
    /// on this connection.
    RequestSupported = -3,

    /// The request code specified in the transmitted Command struct is
    /// supported, but the associated request version is not.
    RequestVersionNotSupported = -2,

    /// The request code specified in the transmitted Command struct is not
    /// supported.
    RequestNotSupported = -1
}
