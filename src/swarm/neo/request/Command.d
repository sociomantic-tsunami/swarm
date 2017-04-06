/*******************************************************************************

    Request command format and global response code definition.

    Copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

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

    Enum defining global status codes transmitted from the node -> client, in
    response to a request.

    Note: there are two types of status code:
        * Global: the codes defined in this module, which may be received by the
          client in response to any request. Global codes have negative values.
        * Request-specific: each request may define whatever status codes it
          needs to inform the client of success/failure/etc. These must have
          positive values.

*******************************************************************************/

public enum GlobalStatusCode : StatusCode
{
    /// The request code specified in the transmitted Command struct is
    /// supported, but the associated request version is not.
    RequestVersionNotSupported = -2,

    /// The request code specified in the transmitted Command struct is not
    /// supported.
    RequestNotSupported = -1
}
