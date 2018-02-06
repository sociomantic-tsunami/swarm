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

public class GetImpl_v0 : IRequest
{
    import integrationtest.neo.common.RequestCodes;
    import integrationtest.neo.common.Get;
    import integrationtest.neo.node.request.mixins.RequestCore;

    mixin RequestCore!();

    /// Request code / version. Required by ConnectionHandler.
    const Command command = Command(RequestCode.Get, 0);

    /// Request name for stats tracking. Required by ConnectionHandler.
    const istring name = "Get";

    /***************************************************************************

        Called by the connection handler after the request code and version have
        been parsed from a message received over the connection, and the
        request-supported code sent in response.

        Params:
            connection = request-on-conn in which the request handler is called
            resources = request resources acquirer
            init_payload = initial message payload read from the connection

    ***************************************************************************/

    public void handle ( RequestOnConn connection, Object resources,
        Const!(void)[] init_payload )
    {
        this.initialise(connection, resources);

        auto ed = this.connection.event_dispatcher;

        hash_t key;
        ed.message_parser.parseBody(init_payload, key);

        auto record = key in this.storage.map;
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
        ed.flush();
    }
}
