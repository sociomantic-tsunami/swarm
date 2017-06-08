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
    import swarm.neo.util.MessageFiber;
    import swarm.neo.request.RequestEventDispatcher;

    /// Fiber which handles iterating and sending records to the client.
    private class Writer
    {
        import swarm.neo.util.DelayedSuspender;

        private MessageFiber fiber;
        private DelayedSuspender suspender;

        public this ( )
        {
            this.fiber = new MessageFiber(&this.fiberMethod, 64 * 1024);
            this.suspender = DelayedSuspender(this.fiber);
        }

        void fiberMethod ( )
        {
            // Iterate over storage, sending records to client.
            foreach ( key, value; this.outer.storage.map )
            {
                this.suspender.suspendIfRequested();

                this.outer.request_event_dispatcher.send(this.fiber,
                    ( RequestOnConn.EventDispatcher.Payload payload )
                    {
                        payload.addConstant(MessageType.Record);
                        payload.add(key);
                        payload.addArray(value);
                    }
                );
            }

            // Send the End message to the client.
            this.outer.request_event_dispatcher.send(this.fiber,
                ( RequestOnConn.EventDispatcher.Payload payload )
                {
                    payload.addConstant(MessageType.End);
                }
            );

            // Kill the controller fiber.
            this.outer.request_event_dispatcher.abort(
                this.outer.controller.fiber);
        }
    }

    /// Fiber which handles control messages from the client.
    private class Controller
    {
        MessageFiber fiber;

        this ( )
        {
            this.fiber = new MessageFiber(&this.fiberMethod, 64 * 1024);
        }

        void fiberMethod ( )
        {
            bool stop;
            do
            {
                // Receive message from client.
                auto message = this.outer.request_event_dispatcher.receive(this.fiber,
                    Message(MessageType.Suspend), Message(MessageType.Resume),
                    Message(MessageType.Stop));

                // Send ACK. The protocol guarantees that the client will not
                // send any further messages until it has received the ACK.
                this.outer.request_event_dispatcher.send(this.fiber,
                    ( RequestOnConn.EventDispatcher.Payload payload )
                    {
                        payload.addConstant(MessageType.Ack);
                    }
                );

                // Carry out the specified control message.
                with ( MessageType ) switch ( message.type )
                {
                    case Suspend:
                        this.outer.writer.suspender.requestSuspension();
                        break;
                    case Resume:
                        this.outer.writer.suspender.resumeIfSuspended();
                        break;
                    case Stop:
                        stop = true;
                        this.outer.request_event_dispatcher.abort(
                            this.outer.writer.fiber);
                        break;
                    default:
                        assert(false);
                }
            }
            while ( !stop );
        }
    }

    /// Storage instance to iterate over.
    private Storage storage;

    /// Connection event dispatcher.
    private RequestOnConn.EventDispatcher conn;

    /// Writer fiber.
    private Writer writer;

    /// Controller fiber.
    private Controller controller;

    /// Multi-fiber event dispatcher.
    private RequestEventDispatcher request_event_dispatcher;

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
        this.storage = storage;
        this.conn = connection.event_dispatcher;

        // Read request setup info from client.
        bool start_suspended;
        this.conn.message_parser.parseBody(msg_payload, start_suspended);

        // Send initial status code response.
        this.conn.send(
            ( conn.Payload payload )
            {
                payload.addConstant(RequestStatusCode.Started);
            }
        );

        // Now ready to start sending data from the storage and to handle
        // control messages from the client. Each of these jobs is handled by a
        // separate fiber.
        this.writer = new Writer;
        this.controller = new Controller;

        if ( start_suspended )
            this.writer.suspender.requestSuspension();

        this.controller.fiber.start();
        this.writer.fiber.start();
        this.request_event_dispatcher.eventLoop(this.conn);
    }
}
