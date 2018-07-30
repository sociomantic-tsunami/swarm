/*******************************************************************************

    Interface for a node request handler object.

    Note that the `ConnectionHandler` (which uses this interface) requires
    implementing classes to have neither constructors nor destructors. The
    reason for this is documented in `ConnectionHandler.emplace`.

    copyright: Copyright (c) 2018 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.neo.node.IRequestHandler;

/// ditto
// This interface is deprecated. When the `RequestMap.add` method that uses it
// is removed, it can also be removed.
public interface IRequestHandler
{
    import ocean.transition;

    import swarm.neo.node.RequestOnConn;

    /***************************************************************************

        Passes the request-on-conn and request resource acquirer to the handler.

        Params:
            connection = request-on-conn in which the request handler is called
            resources = request resources acquirer

    ***************************************************************************/

    void initialise ( RequestOnConn connection, Object resources );

    /***************************************************************************

        Called by the connection handler immediately after the request code and
        version have been parsed from a message received over the connection.
        Allows the request handler to process the remainder of the incoming
        message, before the connection handler sends the supported code back to
        the client.

        Note: the initial payload is a slice of the connection's read buffer.
        This means that when the request-on-conn fiber suspends, the contents of
        the buffer (hence the slice) may change. It is thus *absolutely
        essential* that this method does not suspend the fiber. (This precludes
        all I/O operations on the connection.)

        Params:
            init_payload = initial message payload read from the connection

    ***************************************************************************/

    void preSupportedCodeSent ( Const!(void)[] init_payload );

    /***************************************************************************

        Called by the connection handler after the supported code has been sent
        back to the client.

    ***************************************************************************/

    void postSupportedCodeSent ( );
}

/// ditto
public interface IRequest
{
    import ocean.transition;

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
        Const!(void)[] init_payload );
}
