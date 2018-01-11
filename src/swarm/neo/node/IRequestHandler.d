/*******************************************************************************

    Interface for a node request handler object.

    Note that the `ConnectionHandler` (which uses this interface) requires
    implementing classes to have neither constructors nor destructors. The
    reason for this is documented in `ConnectionHandler.emplace`.

    copyright: Copyright (c) 2018 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.neo.node.IRequestHandler;

/// ditto
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
