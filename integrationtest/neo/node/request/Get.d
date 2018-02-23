/*******************************************************************************

    Internal implementation of the node's Get request.

    Copyright:
        Copyright (c) 2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module integrationtest.neo.node.request.Get;

import ocean.transition;
import integrationtest.neo.node.Storage;
import swarm.neo.node.RequestOnConn;
import swarm.neo.request.Command;
import swarm.neo.node.IRequestHandler;

/*******************************************************************************

    Implementation of the v0 Get request protocol.

*******************************************************************************/

public class GetImpl_v0 : IRequestHandler
{
    import integrationtest.neo.common.Get;
    import integrationtest.neo.node.request.mixins.RequestCore;

    mixin RequestCore!();

    /// Key of record to get.
    private hash_t key;

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

    public void preSupportedCodeSent ( Const!(void)[] init_payload )
    {
        auto parser = this.connection.event_dispatcher.message_parser;
        parser.parseBody(init_payload, this.key);
    }

    /***************************************************************************

        Called by the connection handler after the supported code has been sent
        back to the client.

    ***************************************************************************/

    public void postSupportedCodeSent ( )
    {
        auto ed = this.connection.event_dispatcher;

        auto record = this.key in this.storage.map;
        if ( record is null )
        {
            ed.send(
                ( ed.Payload payload )
                {
                    payload.addCopy(RequestStatusCode.Empty);
                }
            );
        }
        else
        {
            ed.send(
                ( ed.Payload payload )
                {
                    payload.addCopy(RequestStatusCode.Value);
                }
            );

            ed.send(
                ( ed.Payload payload )
                {
                    payload.addArray(*record);
                }
            );
        }
    }
}
