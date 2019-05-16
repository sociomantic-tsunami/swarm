/*******************************************************************************

    Internal implementation of the node's GetAll request.

    Copyright:
        Copyright (c) 2017 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module integrationtest.neo.node.request.GetAll;

import ocean.transition;
import integrationtest.neo.node.Storage;
import swarm.neo.node.RequestOnConn;
import swarm.neo.request.Command;
import swarm.neo.node.IRequest;

/*******************************************************************************

    Implementation of the v0 GetAll request protocol.

*******************************************************************************/

public class GetAllImpl_v0 : IRequest
{
    import integrationtest.neo.common.RequestCodes;
    import integrationtest.neo.common.GetAll;
    import swarm.neo.util.MessageFiber;
    import swarm.neo.request.RequestEventDispatcher;
    import integrationtest.neo.node.request.mixins.RequestCore;

    mixin RequestCore!();

    /// Request code / version. Required by ConnectionHandler.
    static immutable Command command = Command(RequestCode.GetAll, 0);

    /// Request name for stats tracking. Required by ConnectionHandler.
    static immutable istring name = "GetAll";

    /// Flag indicating whether timing stats should be gathered for requests of
    /// this type.
    static immutable bool timing = true;

    /// Flag indicating whether this request type is scheduled for removal. (If
    /// true, clients will be warned.)
    static immutable bool scheduled_for_removal = false;

    /// Set by the Writer when the iteration over the records has finished. Used
    /// by the Controller to ignore incoming messages from that point.
    private bool has_ended;

    /// Code that suspended writer fiber waits for when the request is
    /// suspended.
    static immutable ResumeSuspendedFiber = 1;

    /// Fiber which handles iterating and sending records to the client.
    private class Writer
    {
        import swarm.neo.util.DelayedSuspender;

        private MessageFiber fiber;
        private DelayedSuspender suspender;

        public this ( )
        {
            this.fiber = new MessageFiber(&this.fiberMethod, 64 * 1024);
            this.suspender = DelayedSuspender(
                &this.outer.request_event_dispatcher,
                this.outer.connection.event_dispatcher,
                this.fiber, ResumeSuspendedFiber);
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
                        payload.addCopy(MessageType.Record);
                        payload.add(key);
                        payload.addArray(value);
                    }
                );
            }

            this.outer.has_ended = true;

            // Send the End message to the client.
            this.outer.request_event_dispatcher.send(this.fiber,
                ( RequestOnConn.EventDispatcher.Payload payload )
                {
                    payload.addCopy(MessageType.End);
                }
            );

            this.outer.request_event_dispatcher.receive(this.fiber,
                Message(MessageType.Ack));

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

                // If the request has ended, ignore incoming control messages.
                // We may receive a control message which the client sent before
                // it received or processed the End message we sent.
                if (this.outer.has_ended)
                    continue;

                // Send ACK. The protocol guarantees that the client will not
                // send any further messages until it has received the ACK.
                this.outer.request_event_dispatcher.send(this.fiber,
                    ( RequestOnConn.EventDispatcher.Payload payload )
                    {
                        payload.addCopy(MessageType.Ack);
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

    /// Writer fiber.
    private Writer writer;

    /// Controller fiber.
    private Controller controller;

    /// Multi-fiber event dispatcher.
    private RequestEventDispatcher request_event_dispatcher;

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
        try
        {
            this.initialise(connection, resources);

            bool start_suspended;
            this.connection.event_dispatcher.message_parser.parseBody(
                init_payload, start_suspended);

            // Initialise the RequestEventDispatcher with the delegate that
            // returns (reusable) void[] arrays for the internal usage. The
            // real implementation should pass the delegate that acquires the
            // arrays from the pool, this implementation just returns pointers
            // to the new slices, as we don't care about GC activity here.
            this.request_event_dispatcher.initialise(
                    () { auto slices = new void[][1]; return &slices[0]; });
            // Now ready to start sending data from the storage and to handle
            // control messages from the client. Each of these jobs is handled
            // by a separate fiber.
            this.writer = new Writer;
            this.controller = new Controller;

            if ( start_suspended )
                this.writer.suspender.requestSuspension();

            this.controller.fiber.start();
            this.writer.fiber.start();
            this.request_event_dispatcher.eventLoop(
                this.connection.event_dispatcher);
        }
        catch (Exception e)
        {
            // Inform client about the error
            this.connection.event_dispatcher.send(
                ( RequestOnConn.EventDispatcher.Payload payload )
                {
                    payload.addCopy(MessageType.Error);
                }
            );
        }
    }
}
