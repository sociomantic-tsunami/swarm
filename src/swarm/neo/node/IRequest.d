/*******************************************************************************

    Interface for a node request handler object.

    Note that the `ConnectionHandler` (which uses this interface) requires
    implementing classes to have neither constructors nor destructors. The
    reason for this is documented in `ConnectionHandler.emplace`.

    copyright: Copyright (c) 2018 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.neo.node.IRequest;

/// ditto
public interface IRequest
{
    import ocean.meta.types.Qualifiers;

    import swarm.neo.node.RequestOnConn;

    /***************************************************************************

        Called by the connection handler after the request code and version have
        been parsed from a message received over the connection, and the
        request-supported code sent in response.

        Note: the initial payload passed to this method is a slice of a buffer
        owned by the RequestOnConn. It is thus safe to assume that the contents
        of the buffer will not change over the lifetime of the request.

        Params:
            connection = request-on-conn in which the request handler is called
            resources = request resources acquirer
            init_payload = initial message payload read from the connection

    ***************************************************************************/

    void handle ( RequestOnConn connection, Object resources,
        const(void)[] init_payload );
}
