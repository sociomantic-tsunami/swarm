/*******************************************************************************

    Internal implementation of the node's GetAll request.

    Copyright:
        Copyright (c) 2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module integrationtest.neo.node.request.GetAll;

import ocean.transition;
import integrationtest.neo.node.Storage;
import swarm.neo.node.RequestOnConn;
import swarm.neo.request.Command;
import swarm.neo.node.IRequestHandler;

/*******************************************************************************

    Implementation of the v0 GetAll request protocol.

*******************************************************************************/

public class GetAllImpl_v0 : IRequestHandler
{
    import integrationtest.neo.common.GetAll;
    import swarm.neo.util.MessageFiber;
    import swarm.neo.request.RequestEventDispatcher;
    import integrationtest.neo.node.request.mixins.RequestCore;

    mixin RequestCore!();

    /// Set by the Writer when the iteration over the records has finished. Used
    /// by the Controller to ignore incoming messages from that point.
    private bool has_ended;

    /// Code that suspended writer fiber waits for when the request is
    /// suspended.
    const ResumeSuspendedFiber = 1;

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
            this.outer.connection.event_dispatcher.flush();

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
                this.outer.connection.event_dispatcher.flush();

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

    /// Start request in the suspended state?
    private bool start_suspended;

    /// Writer fiber.
    private Writer writer;

    /// Controller fiber.
    private Controller controller;

    /// Multi-fiber event dispatcher.
    private RequestEventDispatcher request_event_dispatcher;

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
        this.connection.event_dispatcher.message_parser.parseBody(
            init_payload, this.start_suspended);
    }

    /***************************************************************************

        Called by the connection handler after the supported code has been sent
        back to the client.

    ***************************************************************************/

    public void postSupportedCodeSent ( )
    {
        try
        {
            // Now ready to start sending data from the storage and to handle
            // control messages from the client. Each of these jobs is handled
            // by a separate fiber.
            this.writer = new Writer;
            this.controller = new Controller;

            if ( this.start_suspended )
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
