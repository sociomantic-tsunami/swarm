/*******************************************************************************

    Internal implementation of the node's GetAll request.

    Copyright:
        Copyright (c) 2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module test.neo.node.request.GetAll;

import ocean.transition;
import test.neo.node.Storage;
import swarm.neo.node.RequestOnConn;
import swarm.neo.request.Command;

/*******************************************************************************

    The request handler for the table of handlers. When called, runs in a fiber
    that can be controlled via `connection`.

    Params:
        shared_resources = an opaque object containing resources owned by the
            node which are required by the request
        connection  = performs connection socket I/O and manages the fiber
        cmdver      = the version number of the Consume command as specified by
                      the client
        msg_payload = the payload of the first message of this request

*******************************************************************************/

public void handle ( Object shared_resources, RequestOnConn connection,
    Command.Version cmdver, Const!(void)[] msg_payload )
{
    auto storage = cast(Storage)shared_resources;
    assert(storage);

    switch ( cmdver )
    {
        case 0:
            scope rq = new GetAllImpl_v0;
            rq.handle(storage, connection, msg_payload);
            break;

        default:
            auto ed = connection.event_dispatcher;
            ed.send(
                ( ed.Payload payload )
                {
                    payload.addConstant(GlobalStatusCode.RequestVersionNotSupported);
                }
            );
            break;
    }
}

/*******************************************************************************

    Implementation of the v0 GetAll request protocol.

*******************************************************************************/

private scope class GetAllImpl_v0
{
    import test.neo.common.GetAll;

    /***************************************************************************

        Request handler.

        Params:
            storage = storage engine instance to operate on
            connection = connection to client
            msg_payload = initial message read from client to begin the request
                (the request code and version are assumed to be extracted)

    ***************************************************************************/

    final public void handle ( Storage storage, RequestOnConn connection,
        Const!(void)[] msg_payload )
    {
        auto ed = connection.event_dispatcher;

        ed.send(
            ( ed.Payload payload )
            {
                payload.addConstant(RequestStatusCode.Started);
            }
        );

        foreach ( key, value; storage.map )
        {
            ed.send(
                ( ed.Payload payload )
                {
                    payload.addConstant(MessageType.Record);
                    payload.add(key);
                    payload.addArray(value);
                }
            );
        }

        ed.send(
            ( ed.Payload payload )
            {
                payload.addConstant(MessageType.End);
            }
        );
    }
}
