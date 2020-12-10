/*******************************************************************************

    Internal implementation of the node's Put request.

    Copyright:
        Copyright (c) 2017 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module integrationtest.neo.node.request.Put;

import ocean.meta.types.Qualifiers;
import integrationtest.neo.node.Storage;
import swarm.neo.node.RequestOnConn;
import swarm.neo.request.Command;
import swarm.neo.node.IRequest;

/*******************************************************************************

    Implementation of the v0 Put request protocol.

*******************************************************************************/

public class PutImpl_v0 : IRequest
{
    import integrationtest.neo.common.RequestCodes;
    import integrationtest.neo.common.Put;
    import integrationtest.neo.node.request.mixins.RequestCore;

    mixin RequestCore!();

    /// Request code / version. Required by ConnectionHandler.
    static immutable Command command = Command(RequestCode.Put, 0);

    /// Request name for stats tracking. Required by ConnectionHandler.
    static immutable istring name = "Put";

    /// Flag indicating whether timing stats should be gathered for requests of
    /// this type.
    static immutable bool timing = true;

    /// Flag indicating whether this request type is scheduled for removal. (If
    /// true, clients will be warned.)
    static immutable bool scheduled_for_removal = false;

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
        const(void)[] init_payload )
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
    }
}
