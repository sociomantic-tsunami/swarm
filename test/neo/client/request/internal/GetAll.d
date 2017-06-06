/*******************************************************************************

    Internal implementation of the client's GetAll request.

    Copyright:
        Copyright (c) 2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module test.neo.client.request.internal.GetAll;

import ocean.transition;

/*******************************************************************************

    GetAll request implementation.

    Note that request structs act simply as namespaces for the collection of
    symbols required to implement a request. They are never instantiated and
    have no fields or non-static functions.

    The client expects several things to be present in a request struct:
        1. The static constants request_type and request_code
        2. The UserSpecifiedParams struct, containing all user-specified request
            setup (including a notifier)
        3. The Notifier delegate type
        4. Optionally, the Controller type (if the request can be controlled,
           after it has begun)
        5. The handler() function
        6. The all_finished_notifier() function

    The RequestCore mixin provides items 1 and 2.

*******************************************************************************/

public struct GetAll
{
    import test.neo.common.GetAll;
    import test.neo.client.request.GetAll;
    import test.neo.common.RequestCodes;
    import test.neo.client.NotifierTypes;
    import swarm.neo.client.mixins.RequestCore;
    import swarm.neo.client.RequestHandlers : UseNodeDg;

    import ocean.io.select.protocol.generic.ErrnoIOException: IOError;

    /***************************************************************************

        Data which the request needs while it is progress. An instance of this
        struct is stored per connection on which the request runs and is passed
        to the request handler.

    ***************************************************************************/

    private static struct SharedWorking
    {
        /// Flag set when the finished notification has been sent to the user.
        /// Note that, in a real multi-node request, you need to track this
        /// state across each node individually, not at the global level, like
        /// this.
        bool finish_notification_done;
    }

    /***************************************************************************

        Data which each request-on-conn needs while it is progress. An instance
        of this struct is stored per connection on which the request runs and is
        passed to the request handler.

    ***************************************************************************/

    private static struct Working
    {
        // Dummy (not required by this request)
    }

    /***************************************************************************

        Request core. Mixes in the types `NotificationInfo`, `Notifier`,
        `Params`, `Context` plus the static constants `request_type` and
        `request_code`.

    ***************************************************************************/

    mixin RequestCore!(RequestType.AllNodes, RequestCode.GetAll, 0, Args,
        SharedWorking, Working, Notification);

    /***************************************************************************

        Request handler. Called from RequestOnConn.runHandler().

        Params:
            conn = request-on-conn event dispatcher
            context_blob = untyped chunk of data containing the serialized
                context of the request which is to be handled
            working_blob = untyped chunk of data containing the serialized
                working data for the request on this connection

    ***************************************************************************/

    public static void handler ( RequestOnConn.EventDispatcherAllNodes conn,
        void[] context_blob, void[] working_blob )
    {
        auto context = GetAll.getContext(context_blob);

        try
        {
            // Send request info to node
            conn.send(
                ( conn.Payload payload )
                {
                    payload.add(GetAll.cmd.code);
                    payload.add(GetAll.cmd.ver);
                }
            );

            // Receive status from node
            auto status = conn.receiveValue!(StatusCode)();
            if ( GetAll.handleGlobalStatusCodes(status, context,
                conn.remote_address) )
            {
                // Global codes (not supported / version not supported)
                // (Notifier already called.)
                return;
            }
            else
            {
                // GetAll-specific codes
                with ( RequestStatusCode ) switch ( status )
                {
                    case Started:
                        // Expected "request started" code
                        break;

                    case Error:
                        // The node returned an error code. Notify the user and
                        // end the request.
                        Notification n;
                        n.node_error = RequestNodeInfo(
                            context.request_id, conn.remote_address);
                        GetAll.notify(context.user_params, n);
                        return;

                    default:
                        // Treat unknown codes as internal errors.
                        goto case Error;
                }
            }

            scope handler = new Handler(conn, context_blob);
            handler.run();
        }
        catch ( IOError e )
        {
            // A connection error occurred. Notify the user.
            Notification n;
            n.node_disconnected = RequestNodeExceptionInfo(
                context.request_id, conn.remote_address, e);
            GetAll.notify(context.user_params, n);
            context.shared_working.finish_notification_done = true;
        }
    }

    /***************************************************************************

        Request finished notifier. Called from Request.handlerFinished().

        Params:
            context_blob = untyped chunk of data containing the serialized
                context of the request which is finishing
            working_data_iter = iterator over the stored working data associated
                with each connection on which this request was run

    ***************************************************************************/

    public static void all_finished_notifier ( void[] context_blob,
        IRequestWorkingData working_data_iter )
    {
        auto context = GetAll.getContext(context_blob);

        if ( !context.shared_working.finish_notification_done )
        {
            Notification n;
            n.finished = RequestInfo(context.request_id);
            GetAll.notify(context.user_params, n);
        }
    }
}

/*******************************************************************************

    Multi-fiber GetAll handler implementation.

*******************************************************************************/

private scope class Handler
{
    import swarm.neo.request.RequestEventDispatcher;
    import swarm.neo.client.RequestOnConn;
    import test.neo.common.GetAll;
    import test.neo.client.NotifierTypes;
    import swarm.neo.util.MessageFiber;

    /// Token passed to fiber suspend/resume calls.
    private static MessageFiber.Token token =
        MessageFiber.Token("GetAll Handler");

    /// Connection event dispatcher.
    private RequestOnConn.EventDispatcherAllNodes conn;

    /// Request context.
    private GetAll.Context* context;

    /// Reader fiber.
    private Reader reader;

    /// Controller fiber.
    private Controller controller;

    /// Multi-fiber event dispatcher.
    private RequestEventDispatcher request_event_dispatcher;

    /// Enum of signals used by the request fibers.
    private enum Signals
    {
        Stop = 1
    }

    /// Fiber which handles iterating and sending records to the client.
    private class Reader
    {
        private MessageFiber fiber;

        public this ( )
        {
            this.fiber = new MessageFiber(&this.fiberMethod, 64 * 1024);
        }

        void fiberMethod ( )
        {
            uint count;
            bool finished;
            do
            {
                auto message = this.outer.request_event_dispatcher.receive(this.fiber,
                    Message(MessageType.Record), Message(MessageType.End));
                with ( MessageType ) switch ( message.type )
                {
                    case Record:
                        count++;

                        auto key = *conn.message_parser.
                            getValue!(hash_t)(message.payload);
                        auto value = conn.message_parser.
                            getArray!(char)(message.payload);

                        GetAll.Notification n;
                        n.record = RequestKeyDataInfo(context.request_id,
                            key, value);
                        GetAll.notify(context.user_params, n);
                        break;

                    case End:
                        finished = true;
                        break;

                    default:
                        assert(false);
                }

                // Stop the GetAll after some records have been received.
                // In a real client, the request would only be stopped if
                // requested via the user-facing API. In this example, for
                // simplicity, the Reader triggers a Stop message.
                if ( count == 5 )
                    this.outer.request_event_dispatcher.signal(this.outer.conn,
                        Signals.Stop);
            }
            while ( !finished );

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
            // Wait for a control message to be initiated.
            // In a real client, there would be a user-facing API to do this. In
            // this example, for simplicity, the Reader triggers a control
            // message.
            auto event = this.outer.request_event_dispatcher.nextEvent(
                this.fiber, Signal(Signals.Stop));
            assert(event.signal.code == Signals.Stop);

            // Send Stop message to node.
            this.outer.request_event_dispatcher.send(this.fiber,
                ( RequestOnConn.EventDispatcher.Payload payload )
                {
                    payload.addConstant(MessageType.Stop);
                }
            );

            // Receive ACK from node.
            auto message = this.outer.request_event_dispatcher.receive(this.fiber,
                Message(MessageType.Ack));
            assert(message.type == MessageType.Ack);

            // Kill the reader fiber.
            this.outer.request_event_dispatcher.abort(
                this.outer.reader.fiber);
        }
    }

    /***************************************************************************

        Constructor.

        Params:
            conn = Event dispatcher for this connection
            context_blob = serialized request context

    ***************************************************************************/

    public this ( RequestOnConn.EventDispatcherAllNodes conn,
                  void[] context_blob )
    {
        this.conn = conn;
        this.context = GetAll.getContext(context_blob);
    }

    public void run ( )
    {
        // Start reading data from the node and handling control messages. Each
        // of these jobs is handled by a separate fiber.
        this.reader = new Reader;
        this.controller = new Controller;

        this.controller.fiber.start();
        this.reader.fiber.start();
        this.request_event_dispatcher.eventLoop(this.conn);
    }
}
