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
    import swarm.neo.client.mixins.SuspendableRequestCore;
    import swarm.neo.client.mixins.AllNodesRequestCore;

    import ocean.io.select.protocol.generic.ErrnoIOException: IOError;

    /***************************************************************************

        Data which the request needs while it is progress. An instance of this
        struct is stored per connection on which the request runs and is passed
        to the request handler.

    ***************************************************************************/

    private static struct SharedWorking
    {
        /// Shared working data required for core all-nodes request behaviour.
        AllNodesRequestSharedWorkingData all_nodes;

        /// Shared working data required for core suspendable behaviour.
        SuspendableRequestSharedWorkingData suspendable_control;
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

        Suspendable controller scope class which implements the IController
        interface declared in the API module for this request.

    ***************************************************************************/

    mixin SuspendableController!(GetAll, IController, MessageType);

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

        scope request_impl = new GetAllImpl(conn, context);
        request_impl.run();
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

        if ( !context.shared_working.suspendable_control.
            stopped_notification_done )
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

private scope class GetAllImpl
{
    import swarm.neo.connection.RequestOnConnBase;
    import swarm.neo.client.mixins.AllNodesRequestCore;
    import swarm.neo.client.mixins.SuspendableRequestCore;
    import swarm.neo.request.RequestEventDispatcher;
    import swarm.neo.client.RequestOnConn;
    import swarm.neo.util.MessageFiber;

    import test.neo.common.GetAll;
    import test.neo.client.NotifierTypes;

    import test.neo.common.GetAll;
    import test.neo.client.NotifierTypes;

    /// Connection event dispatcher.
    private RequestOnConn.EventDispatcherAllNodes conn;

    /// Request context.
    private GetAll.Context* context;

    /***************************************************************************

        Constructor.

        Params:
            conn = request-on-conn event dispatcher
            context = request context

    ***************************************************************************/

    public this ( RequestOnConn.EventDispatcherAllNodes conn,
        GetAll.Context* context )
    {
        this.conn = conn;
        this.context = context;
    }

    /***************************************************************************

        Runs the request handler.

    ***************************************************************************/

    public void run ( )
    {
        auto request = createSuspendableRequest!(GetAll)(this.conn, this.context,
            &this.connect, &this.disconnected, &this.fillPayload,
            &this.handleStatusCode, &this.handle);
        request.run();
    }

    /***************************************************************************

        Connect policy, called from AllNodesRequest template to ensure the
        connection to the node is up.

        Returns:
            true to continue handling the request; false to abort

    ***************************************************************************/

    private bool connect ( )
    {
        return suspendableRequestConnector(this.conn,
            &this.context.shared_working.suspendable_control);
    }

    /***************************************************************************

        Disconnected policy, called from AllNodesRequest template when an I/O
        error occurs on the connection.

        Params:
            e = exception indicating error which occurred on the connection

    ***************************************************************************/

    private void disconnected ( Exception e )
    {
        // Notify the user of the disconnection. The user may use the
        // controller, at this point, but as the request is not active
        // on this connection, no special behaviour is needed.
        GetAll.Notification notification;
        notification.node_disconnected =
            RequestNodeExceptionInfo(this.context.request_id,
            this.conn.remote_address, e);
        GetAll.notify(this.context.user_params, notification);
    }

    /***************************************************************************

        FillPayload policy, called from SuspendableRequestInitialiser template
        to add request-specific data to the initial message payload send to the
        node to begin the request.

    ***************************************************************************/

    private void fillPayload ( RequestOnConnBase.EventDispatcher.Payload payload )
    {
        this.context.shared_working.suspendable_control.fillPayload(payload);
    }

    /***************************************************************************

        HandleStatusCode policy, called from SuspendableRequestInitialiser
        template to decide how to handle the status code received from the node.

        Params:
            status = status code received from the node in response to the
                initial message

        Returns:
            true to continue handling the request (OK status); false to abort
            (error status)

    ***************************************************************************/

    private bool handleStatusCode ( ubyte status )
    {
        auto getall_status = cast(RequestStatusCode)status;

        if ( GetAll.handleGlobalStatusCodes(getall_status, this.context,
            this.conn.remote_address) )
            return false; // Global code, e.g. request/version not supported

        // GetAll-specific codes
        with ( RequestStatusCode ) switch ( getall_status )
        {
            case Started:
                // Expected "request started" code
                return true;

            case Error:
                // The node returned an error code. Notify the user and
                // end the request.
                GetAll.Notification n;
                n.node_error = RequestNodeInfo(
                    this.context.request_id, conn.remote_address);
                GetAll.notify(this.context.user_params, n);
                return false;

            default:
                // Treat unknown codes as internal errors.
                goto case Error;
        }

        assert(false);
    }

    /***************************************************************************

        Handler policy, called from AllNodesRequest template to run the
        request's main handling logic.

    ***************************************************************************/

    private void handle ( )
    {
        RequestEventDispatcher request_event_dispatcher;
        Reader reader;
        Controller controller;

        // Note: this request heap allocates two fibers each time it is handled.
        // In a real client implementation, you would want to get these fibers
        // from a pool, to avoid allocating each time.
        reader = Reader(new MessageFiber(&reader.fiberMethod, 64 * 1024),
            &request_event_dispatcher, this.conn, this.context, &controller);
        controller = Controller(new MessageFiber(&controller.fiberMethod, 64 * 1024),
            &request_event_dispatcher, this.conn, this.context, &reader);

        controller.fiber.start();
        reader.fiber.start();

        if ( this.context.shared_working.all_nodes.num_initialising == 0 )
        {
            if ( this.context.shared_working.suspendable_control.
                allInitialised!(GetAll)(this.context) )
            {
                request_event_dispatcher.signal(this.conn,
                    SuspendableRequestSharedWorkingData.Signal.StateChangeRequested);
            }
        }

        request_event_dispatcher.eventLoop(this.conn);

        assert(controller.fiber.finished());
        assert(reader.fiber.finished());
    }
}

/// Fiber which handles iterating and sending records to the client.
private struct Reader
{
    import swarm.neo.util.MessageFiber;
    import swarm.neo.request.RequestEventDispatcher;
    import swarm.neo.client.RequestOnConn;
    import test.neo.common.GetAll;
    import test.neo.client.NotifierTypes;

    private MessageFiber fiber;
    private RequestEventDispatcher* request_event_dispatcher;
    private RequestOnConn.EventDispatcherAllNodes conn;
    private GetAll.Context* context;
    private Controller* controller;

    void fiberMethod ( )
    {
        auto suspendable_control =
            &this.context.shared_working.suspendable_control;

        bool finished;
        do
        {
            auto message = this.request_event_dispatcher.receive(this.fiber,
                Message(MessageType.Record), Message(MessageType.End));
            with ( MessageType ) switch ( message.type )
            {
                case Record:
                    auto key = *this.conn.message_parser.
                        getValue!(hash_t)(message.payload);
                    auto value = this.conn.message_parser.
                        getArray!(char)(message.payload);

                    GetAll.Notification n;
                    n.record = RequestKeyDataInfo(this.context.request_id,
                        key, value);
                    if ( suspendable_control.notifyAndCheckStateChange!(GetAll)(
                        this.context, n) )
                    {
                        // The user used the controller in the notifier callback
                        this.request_event_dispatcher.signal(this.conn,
                            suspendable_control.Signal.StateChangeRequested);
                    }
                    break;

                case End:
                    finished = true;
                    break;

                default:
                    assert(false);
            }
        }
        while ( !finished );

        // Acknowledge the End signal. The protocol guarantees that the node
        // will not send any further messages.
        this.request_event_dispatcher.send(this.fiber,
            ( RequestOnConn.EventDispatcher.Payload payload )
            {
                payload.addConstant(MessageType.Ack);
            }
        );
        this.conn.flush();

        // Kill the controller fiber.
        this.request_event_dispatcher.abort(this.controller.fiber);
    }
}

/// Fiber which handles control messages from the client.
private struct Controller
{
    import swarm.neo.util.MessageFiber;
    import swarm.neo.request.RequestEventDispatcher;
    import swarm.neo.client.RequestOnConn;
    import swarm.neo.client.mixins.SuspendableRequestCore;
    import test.neo.common.GetAll;

    private MessageFiber fiber;
    private RequestEventDispatcher* request_event_dispatcher;
    private RequestOnConn.EventDispatcherAllNodes conn;
    private GetAll.Context* context;
    private Reader* reader;

    void fiberMethod ( )
    {
        SuspendableRequestControllerFiber!(GetAll, MessageType) controller;
        controller.handle(this.conn, this.context,
            this.request_event_dispatcher, this.fiber);

        // Kill the reader fiber; the request is finished.
        this.request_event_dispatcher.abort(this.reader.fiber);
    }
}
