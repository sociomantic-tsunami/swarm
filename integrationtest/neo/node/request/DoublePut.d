/*******************************************************************************

    Internal implementation of the node's DoublePut request.

    Copyright:
        Copyright (c) 2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module integrationtest.neo.node.request.DoublePut;

import ocean.transition;
import integrationtest.neo.node.Storage;
import swarm.neo.node.RequestOnConn;
import swarm.neo.request.Command;
import swarm.neo.node.IRequestHandler;

/*******************************************************************************

    Implementation of the v0 DoublePut request protocol.

*******************************************************************************/

public class DoublePutImpl_v0 : IRequest
{
    import integrationtest.neo.common.RequestCodes;
    import integrationtest.neo.common.DoublePut;
    import integrationtest.neo.node.request.mixins.RequestCore;

    mixin RequestCore!();

    /// Request code / version. Required by ConnectionHandler.
    const Command command = Command(RequestCode.DoublePut, 0);

    /// Request name for stats tracking. Required by ConnectionHandler.
    const istring name = "DoublePut";

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
        cstring value;
        ed.message_parser.parseBody(init_payload, key, value);

        this.storage.map[key] = value.dup;

        ed.send(
            ( ed.Payload payload )
            {
                payload.addCopy(RequestStatusCode.Succeeded);
            }
        );
        ed.flush();
    }
}
