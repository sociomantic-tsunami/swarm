/*******************************************************************************

    Helpers encapsulating core behaviour for suspendable all-nodes requests.

    The following helpers, building on top of the helpers in
    swarm.neo.client.mixins.AllNodesRequestCore, exist in this module:

    * suspendableRequestConnector: function providing the standard logic for
      connecting a request-on-conn of a suspendable all-nodes request. To be
      called from the Connector policy instance of an AllNodesRequest (see
      swarm.neo.client.mixins.AllNodesRequestCore).

    * SuspendableRequestInitialiser: struct template encapsulating the logic for
      initialising a suspendable all-nodes request. Extends the behaviour of the
      AllNodesRequestInitialiser with the following:
        * If the desired state of the request (as specified by the user, via the
          controller) is Stopped, then the initialisation is aborted.
        * After initialisation is complete, the ready_for_state_change counter
          in the request's SuspendableRequestSharedWorkingData is incremented.
        * When initialisation is reset (via AllNodesRequest), the
          ready_for_state_change counter in the request's
          SuspendableRequestSharedWorkingData is decremented.

    * createSuspendableRequestInitialiser: helper function to instantiate
      SuspendableRequestInitialiser. Using this function allows the compiler to
      infer the template arguments of SuspendableRequestInitialiser from the
      types of the function arguments.

    * createSuspendableRequest: helper function to instantiate AllNodesRequest
      with a SuspendableRequestInitialiser. Using this function allows the
      compiler to infer the template arguments of AllNodesRequest and
      SuspendableRequestInitialiser from the types of the function arguments.

    * SuspendableController: template mixin containing a class that implements
      the standard logic for a request controller accessible via the user API.
      Has public methods suspend(), resume(), and stop().

    * SuspendableRequestControllerFiber: struct encapsulating the standard logic
      for a controller fiber -- for use in a multi-fiber request -- which awaits
      state change signals from the user-facing controller class (see
      SuspendableController) and sends the corresponding messages to the node.

    * SuspendableRequestSharedWorkingData: struct encapsulating shared working
      data required by the helpers in this module. If using these helpers, a
      field of type SuspendableRequestSharedWorkingData, named
      suspendable_control must be added to the request's shared working data
      struct.

    Copyright: Copyright (c) 2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.neo.client.mixins.SuspendableRequestCore;

import swarm.neo.client.RequestOnConn;
import swarm.neo.client.mixins.AllNodesRequestCore;

/*******************************************************************************

    Helper function providing the standard logic for connecting a request-on-
    conn of a suspendable all-nodes request. To be called from the Connector
    policy instance of an AllNodesRequest.

    Suspends the specified request-on-conn until the connection is established
    or the user instructs the request to stop.

    Params:
        conn = request-on-conn to suspend until the connection is established
        suspendable_control = pointer to the SuspendableRequestSharedWorkingData
            instance stored in the request's shared working data

    Returns:
        true (indicates that the request should be initialised) on successful
        connection; false (indicates that the request should be aborted) if the
        user wishes to stop the request

*******************************************************************************/

public bool suspendableRequestConnector (
    RequestOnConn.EventDispatcherAllNodes conn,
    SuspendableRequestSharedWorkingData* suspendable_control )
{
    bool connected = false;
    do
    {
        auto resume_code = conn.waitForReconnect();
        switch ( resume_code )
        {
            case conn.FiberResumeCodeReconnected:
            case 0: // The connection is already up
                connected = true;
                break;

            case SuspendableRequestSharedWorkingData.Signal.StateChangeRequested:
                if ( suspendable_control.desired_state ==
                    suspendable_control.desired_state.Stopped )
                    // The user requested to stop this request, so we don't
                    // need to wait for a reconnection any more.
                    return false;
                else
                    break;

            default:
                assert(false);
        }
    }
    while ( !connected );

    return true;
}

///
unittest
{
    // Example request struct with RequestCore mixed in
    struct ExampleRequest
    {
        mixin ExampleRequestCore!();
    }

    // (Partial) request implementation, to be instantiated from the request's
    // handler function.
    scope class ExampleRequestImpl
    {
        private RequestOnConn.EventDispatcherAllNodes conn;
        private ExampleRequest.Context* context;

        public this ( RequestOnConn.EventDispatcherAllNodes conn,
            ExampleRequest.Context* context )
        {
            this.conn = conn;
            this.context = context;
        }

        // Method to be passed (as a delegate) as the Connector policy of
        // AllNodesRequest. Forwards to suspendableRequestConnector.
        private bool connect ( )
        {
            return suspendableRequestConnector(this.conn,
                &this.context.shared_working.suspendable_control);
        }
    }
}

/*******************************************************************************

    Struct template encapsulating the core logic for initialising a single
    request-on-conn of a suspendable all-nodes request. Internally, an instance
    of AllNodesRequestInitialiser is used to handle the basic initialisation
    process. The following additional logic is performed:
        * If the desired state of the request (as specified by the user, via the
          controller) is Stopped, then the initialisation is aborted.
        * After initialisation is complete, the ready_for_state_change counter
          in the request's SuspendableRequestSharedWorkingData is incremented.
        * When initialisation is reset (via AllNodesRequest), the
          ready_for_state_change counter in the request's
          SuspendableRequestSharedWorkingData is decremented.

    This struct is suitable for passing to AllNodesRequest as the Initialiser
    policy.

    Note that this initialiser requires the following fields to exist in the
    request's shared working data:
        * A field named all_nodes, of type AllNodesRequestSharedWorkingData.
        * A field named suspendable_control of type
          SuspendableRequestSharedWorkingData.

    The fields of both of these structs are used by the initialiser and should
    not be touched by other code.

    Params:
        Request = type of the request being initialised. The request's shared
            working data is expected to contain a field of type
            AllNodesRequestSharedWorkingData called all_nodes
        FillPayload = type of policy instance to be called to add any required
            fields to the initial message payload sent to the node
        HandleStatusCode = type of policy instance to be called to validate the
            status code received from the node. Should return true to continue
            handling the request or false to abort

*******************************************************************************/

public struct SuspendableRequestInitialiser ( Request, FillPayload,
    HandleStatusCode )
{
    import swarm.neo.client.RequestOnConn;
    import swarm.neo.connection.RequestOnConnBase;
    import swarm.neo.client.mixins.AllNodesRequestCore : AllNodesRequestInitialiser;

    /// Struct encapsulating the logic for inc/decrementing the request's
    /// SuspendableRequestSharedWorkingData.ready_for_state_change counter.
    private struct StateChangeReadinessTracker
    {
        /// Pointer to request's SuspendableRequestSharedWorkingData.
        private SuspendableRequestSharedWorkingData* suspendable_control;

        invariant ( )
        {
            assert((&this).suspendable_control !is null);
        }

        /// Flag indicating whether the request's
        /// SuspendableRequestSharedWorkingData.ready_for_state_change counter
        /// has already been incremented for this request-on-conn.
        private bool ready_for_state_change;

        /***********************************************************************

            Sets or clears the ready_for_state_change field and updates the
            SuspendableRequestSharedWorkingData.ready_for_state_change counter
            as appropriate. (Setting the same value twice in a row has no
            effect.)

            Params:
                ready = value to set for readiness flag

        ***********************************************************************/

        public void opAssign ( bool ready )
        {
            if ( ready )
            {
                if ( !(&this).ready_for_state_change )
                {
                    (&this).ready_for_state_change = true;
                    (&this).suspendable_control.ready_for_state_change++;
                }
            }
            else
            {
                if ( (&this).ready_for_state_change )
                {
                    assert((&this).suspendable_control.ready_for_state_change > 0);
                    (&this).ready_for_state_change = false;
                    (&this).suspendable_control.ready_for_state_change--;
                }
            }
        }
    }

    /// All-nodes initialiser used internally.
    private AllNodesRequestInitialiser!(Request, FillPayload, HandleStatusCode)
        all_nodes_initialiser;

    /// State change readiness tracker instance.
    private StateChangeReadinessTracker ready_for_state_change;

    /***************************************************************************

        Performs the logic of request initialisation. Called by
        AllNodesRequestHandler.

        Returns:
            true if initialisation succeeded for this request-on-conn, false to
            abort handling of the request on this connection

    ***************************************************************************/

    public bool initialise ( )
    {
        (&this).ready_for_state_change.suspendable_control =
            &(&this).all_nodes_initialiser.context.shared_working.
                suspendable_control;

        auto suspendable_control =
            &(&this).all_nodes_initialiser.context.shared_working.suspendable_control;

        // If the desired state is already Stopped, simply abort initialisation
        if ( suspendable_control.desired_state ==
            suspendable_control.desired_state.Stopped )
            return false;

        // Perform standard all-nodes initialisation
        if ( !(&this).all_nodes_initialiser.initialise() )
            return false;

        (&this).ready_for_state_change = true;

        return true;
    }

    /***************************************************************************

        Called by AllNodesRequest to reset any state required for initialisation
        to begin again. Decrements the
        SuspendableRequestSharedWorkingData.ready_for_state_change counter, if
        it has been incremented for this request-on-conn.

    ***************************************************************************/

    public void reset ( )
    {
        (&this).all_nodes_initialiser.reset();

        (&this).ready_for_state_change = false;
    }
}

/*******************************************************************************

    Helper function to instantiate SuspendableRequestInitialiser. Using this
    function allows the compiler to infer the template arguments of
    SuspendableRequestInitialiser from the types of the function arguments.

    Params:
        Request = type of the request being initialised
        FillPayload = type of policy instance to be called to add any required
            fields to the initial message payload sent to the node
        HandleStatusCode = type of policy instance to be called to validate the
            status code received from the node
        conn = request-on-conn event dispatcher to use for handling the request
        context = request context
        fill_payload = instance of FillPayload
        handle_status_code = instance of HandleStatusCode

    Returns:
        instance of SuspendableRequestInitialiser constructed with the provided
        arguments

*******************************************************************************/

public
    SuspendableRequestInitialiser!(Request, FillPayload, HandleStatusCode)
    createSuspendableRequestInitialiser
        ( Request, FillPayload, HandleStatusCode )
        ( RequestOnConn.EventDispatcherAllNodes conn, Request.Context* context,
          FillPayload fill_payload, HandleStatusCode handle_status_code )
{
    return
        SuspendableRequestInitialiser!(Request, FillPayload, HandleStatusCode)
        (createAllNodesRequestInitialiser!(Request)(conn, context, fill_payload,
        handle_status_code));
}

///
unittest
{
    // Example request struct with RequestCore mixed in
    struct ExampleRequest
    {
        mixin ExampleRequestCore!();
    }

    // (Partial) request implementation, to be instantiated from the request's
    // handler function.
    scope class ExampleRequestImpl
    {
        import swarm.neo.connection.RequestOnConnBase;

        private RequestOnConn.EventDispatcherAllNodes conn;
        private ExampleRequest.Context* context;

        public this ( RequestOnConn.EventDispatcherAllNodes conn,
            ExampleRequest.Context* context )
        {
            this.conn = conn;
            this.context = context;
        }

        // Instantiates a SuspendableRequestInitialiser with dummy delegates
        // passed as the various policies.
        public void run ( )
        {
            auto initialiser = createSuspendableRequestInitialiser!(ExampleRequest)(
                this.conn, this.context, &this.fillPayload,
                &this.handleStatusCode);

            // Pass initialiser to an AllNodesRequest...
        }

        // Dummy policies...
        private void fillPayload (
            RequestOnConnBase.EventDispatcher.Payload payload ) { }

        private bool handleStatusCode ( ubyte status )
        {
            return true;
        }
    }
}

/*******************************************************************************

    Helper function to instantiate AllNodesRequest with a
    SuspendableRequestInitialiser. Using this function allows the compiler to
    infer the template arguments of AllNodesRequest and
    SuspendableRequestInitialiser from the types of the function arguments.

    Params:
        Request = type of the request being handled
        Connector = type of policy instance to be called to perform connection
            establishment (see AllNodesRequest)
        Disconnected = type of policy instance to be called when an I/O error
            causes the connection to the node to break (see AllNodesRequest)
        FillPayload = type of policy instance to be called to add any required
            fields to the initial message payload sent to the node
        HandleStatusCode = type of policy instance to be called to validate the
            status code received from the node
        Handler = type of policy instance to be called to handle the main logic
            of the request (see AllNodesRequest)
        conn = request-on-conn event dispatcher to use for handling the request
        context = request context
        connector = instance of Connector policy
        disconnected = instance of Disconnected policy
        fill_payload = instance of FillPayload
        handle_status_code = instance of HandleStatusCode
        handler = instance of Handler policy

    Returns:
        instance of AllNodesRequest constructed with the provided arguments

*******************************************************************************/

public
    AllNodesRequest!(Request, Connector, Disconnected,
        SuspendableRequestInitialiser!(Request, FillPayload, HandleStatusCode),
        Handler)
    createSuspendableRequest
        ( Request, Connector, Disconnected, FillPayload,
          HandleStatusCode, Handler )
        ( RequestOnConn.EventDispatcherAllNodes conn, Request.Context* context,
          Connector connector, Disconnected disconnected,
          FillPayload fill_payload, HandleStatusCode handle_status_code,
          scope Handler handler )
{
    auto initialiser = createSuspendableRequestInitialiser!(Request)(
        conn, context, fill_payload, handle_status_code);
    return
        AllNodesRequest!(Request, Connector, Disconnected, typeof(initialiser),
        Handler)
        (connector, disconnected, initialiser, handler, conn, context);
}

///
unittest
{
    // Example request struct with RequestCore mixed in
    struct ExampleRequest
    {
        mixin ExampleRequestCore!();
    }

    // (Partial) request implementation, to be instantiated from the request's
    // handler function.
    scope class ExampleRequestImpl
    {
        import swarm.neo.connection.RequestOnConnBase;

        private RequestOnConn.EventDispatcherAllNodes conn;
        private ExampleRequest.Context* context;

        public this ( RequestOnConn.EventDispatcherAllNodes conn,
            ExampleRequest.Context* context )
        {
            this.conn = conn;
            this.context = context;
        }

        // Instantiates an AllNodesRequest with a SuspendableRequestInitialiser
        // and dummy delegates passed as the various policies.
        public void run ( )
        {
            auto request = createSuspendableRequest!(ExampleRequest)(
                this.conn, this.context, &this.connect, &this.disconnected,
                &this.fillPayload, &this.handleStatusCode, &this.handle);
            request.run();
        }

        // Dummy policies...
        private bool connect ( )
        {
            return true;
        }

        private void disconnected ( Exception e ) { }

        private void fillPayload (
            RequestOnConnBase.EventDispatcher.Payload payload ) { }

        private bool handleStatusCode ( ubyte status )
        {
            return true;
        }

        private void handle ( ) { }
    }
}

/*******************************************************************************

    Mixes in a controller class for a request (assumed to contain the features
    of swarm.neo.client.mixins.RequestCore : RequestCore) which is suspendable,
    resumable, and stoppable. The class implements the interface IController
    (specified as a template argument), assumed to have methods suspend(),
    resume(), and stop(). (Note that this interface is not provided in the
    library purely in order to keep all API definitions for each request inside
    a single module, not scattered around different modules in swarm.)

    Params:
        Request = type of request struct
        IController = interface defining the controller API as presented to the
            user. Assumed to contain methods suspend(), resume(), and stop() (in
            addition to any other methods required by the request).
        MessageType = type of enum defining the types of messages used by this
            request's protocol. Expected to contain the members Suspend, Resume,
            and Stop (in addition to any others required by the request).

*******************************************************************************/

public template SuspendableController ( Request, IController, MessageType )
{
    /***************************************************************************

        Request controller, accessible to the user via the client's `control()`
        method.

    ***************************************************************************/

    public scope class Controller : IController
    {
        import ocean.core.Enforce;
        import swarm.neo.client.mixins.RequestCore : ControllerBase;

        /***********************************************************************

            Base mixin.

        ***********************************************************************/

        mixin ControllerBase;

        /***********************************************************************

            Tells the nodes to stop sending data to this request.

            Returns:
                false if the controller cannot be used because a control change
                is already in progress

        ***********************************************************************/

        public bool suspend ( )
        {
            return this.changeDesiredState(MessageType.Suspend);
        }

        /***********************************************************************

            Tells the nodes to resume sending data to this request.

            Returns:
                false if the controller cannot be used because a control change
                is already in progress

        ***********************************************************************/

        public bool resume ( )
        {
            return this.changeDesiredState(MessageType.Resume);
        }

        /***********************************************************************

            Tells the nodes to cleanly end the request.

            Returns:
                false if the controller cannot be used because a control change
                is already in progress

        ***********************************************************************/

        public bool stop ( )
        {
            return this.changeDesiredState(MessageType.Stop);
        }

        /***********************************************************************

            Changes the desired state to that specified. Sets the desired state
            flag and resumes any handler fibers which are suspended, passing the
            control message flag to the fiber via the return value of suspend().

            If one or more connections are not ready to change state, the
            control change does not occur. A connection is ready to change the
            request state unless the handler is currently waiting for an
            acknowledgement message when beginning the request or changing its
            state.

            Params:
                code = desried state

            Returns:
                true if the state change has been accepted and will be sent to
                all active nodes, false if one or more connections is already in
                the middle of changing state

        ***********************************************************************/

        private bool changeDesiredState ( MessageType code )
        {
            auto context =
                Request.getContext(this.request_controller.context_blob);
            auto suspendable_control =
                &context.shared_working.suspendable_control;

            if ( suspendable_control.changing_state )
                return false;

            auto info = RequestInfo(context.request_id);
            Request.Notification notification;

            // Set the desired state in the shared working data
            with ( MessageType ) switch ( code )
            {
                case Resume:
                    suspendable_control.desired_state =
                        suspendable_control.DesiredState.Running;
                    notification.resumed = info;
                    break;
                case Suspend:
                    suspendable_control.desired_state =
                        suspendable_control.DesiredState.Suspended;
                    notification.suspended = info;
                    break;
                case Stop:
                    suspendable_control.desired_state =
                        suspendable_control.DesiredState.Stopped;
                    notification.stopped = info;
                    break;

                default: assert(false,
                    Request.stringof ~ ".Controller: Unexpected message type");
            }

            // If one or more connections are ready to send a state change
            // message to the node, we initiate this.
            if ( suspendable_control.ready_for_state_change )
            {
                this.request_controller.resumeSuspendedHandlers(
                    SuspendableRequestSharedWorkingData.Signal.StateChangeRequested);
            }
            // If no connections are ready to send state change messages, the
            // state change essentially occurs immediately (without the need for
            // node contact). We just call the notifier.
            else
            {
                Request.notify(context.user_params, notification);
            }

            return true;
        }
    }
}

///
unittest
{
    // Example request struct with RequestCore and SuspendableController mixed in
    struct ExampleRequest
    {
        mixin ExampleRequestCore!();

        // Required by SuspendableController
        enum MessageType
        {
            Suspend,
            Resume,
            Stop
        }

        // Required by SuspendableController
        interface IController
        {
            bool suspend ( );
            bool resume ( );
            bool stop ( );
        }

        mixin SuspendableController!(ExampleRequest, IController, MessageType);
    }
}

/*******************************************************************************

    Struct encapsulating the standard logic for a controller fiber -- for use in
    a multi-fiber request -- which awaits state change signals from the user-
    facing controller class (see SuspendableController) and sends the
    corresponding messages to the node.

    Params:
        Request = type of request struct
        MessageType = type of enum defining the types of messages used by this
            request's protocol. Expected to contain the members Suspend, Resume,
            Stop, and Ack (in addition to any others required by the request).

*******************************************************************************/

public struct SuspendableRequestControllerFiber ( Request, MessageType )
{
    import swarm.neo.util.MessageFiber;

    import swarm.neo.client.NotifierTypes;
    import swarm.neo.client.RequestOnConn;
    import swarm.neo.request.RequestEventDispatcher;

    /// Request-on-conn event dispatcher.
    private RequestOnConn.EventDispatcherAllNodes conn;

    /// Request context.
    private Request.Context* context;

    /// Multi-fiber request event dispatcher.
    private RequestEventDispatcher* request_event_dispatcher;

    /// Fiber to suspend when waiting for I/O.
    private MessageFiber fiber;

    /***************************************************************************

        Performs the logic of awaiting state change signals from the user-facing
        controller class (see SuspendableController) and sending the
        corresponding messages to the node.

        Returns only when the request has been stopped by the user.

        Params:
            conn = request-on-conn event dispatcher
            context = request context
            request_event_dispatcher = multi-fiber request event dispatcher
            fiber = fiber to suspend when waiting for I/O

    ***************************************************************************/

    public void handle ( RequestOnConn.EventDispatcherAllNodes conn,
        Request.Context* context, RequestEventDispatcher* request_event_dispatcher,
        MessageFiber fiber )
    {
        (&this).conn = conn;
        (&this).context = context;
        (&this).request_event_dispatcher = request_event_dispatcher;
        (&this).fiber = fiber;

        auto suspendable_control =
            &(&this).context.shared_working.suspendable_control;

        bool stopped, state_changed_in_notifier;
        do
        {
            if ( !state_changed_in_notifier )
            {
                // Wait for user action.
                auto event = (&this).request_event_dispatcher.nextEvent((&this).fiber,
                    Signal(suspendable_control.Signal.StateChangeRequested));
                assert(event.active == event.active.signal);
                assert(event.signal.code == suspendable_control.Signal.StateChangeRequested);
            }

            // Send state change message to node and wait for ACK.
            stopped = (&this).changeRequestState();

            // Notify the user that the state change has taken effect and handle
            // the case where they request a new state change in the notifier.
            state_changed_in_notifier = (&this).notifyUser();
        }
        while ( !stopped );
    }

    /***************************************************************************

        Sends a message to the node to carry out the state change initiated by
        the user, then waits for the ACK message back from the node.

        Returns:
            true if the state change was to stop the request

    ***************************************************************************/

    private bool changeRequestState ( )
    {
        auto suspendable_control =
            &(&this).context.shared_working.suspendable_control;

        suspendable_control.changing_state++;
        scope ( exit )
            suspendable_control.changing_state--;

        // Determine message type.
        MessageType msg;
        with ( suspendable_control.DesiredState )
        switch ( suspendable_control.desired_state )
        {
            case Running:
                msg = MessageType.Resume;
                break;
            case Suspended:
                msg = MessageType.Suspend;
                break;
            case Stopped:
                msg = MessageType.Stop;
                break;
            default:
                assert(false);
        }

        // Send message to node.
        (&this).request_event_dispatcher.send((&this).fiber,
            ( conn.Payload payload )
            {
                payload.add(msg);
            }
        );
        (&this).conn.flush();

        // Wait for ACK.
        (&this).request_event_dispatcher.receive((&this).fiber,
            Message(MessageType.Ack));

        return msg == MessageType.Stop;
    }

    /***************************************************************************

        After a state change has been carried out by the node, notifies the user
        if this was the last request-on-conn to carry out the state change. Also
        checks for the case that the user initiates another state change in the
        notifier call (see return value).

        Returns:
            true if another state change was requested during notification

    ***************************************************************************/

    private bool notifyUser ( )
    {
        auto suspendable_control =
            &(&this).context.shared_working.suspendable_control;

        bool state_changed_in_notifier;

        // If the state change has been carried out on all nodes, notify the
        // user that the state change is complete.
        if ( suspendable_control.changing_state == 0 )
        {
            // Set up notification.
            Request.Notification notification;
            with ( suspendable_control.DesiredState )
            switch ( suspendable_control.desired_state )
            {
                case Running:
                    notification.resumed = RequestInfo((&this).context.request_id);
                    break;
                case Suspended:
                    notification.suspended = RequestInfo((&this).context.request_id);
                    break;
                case Stopped:
                    notification.stopped = RequestInfo((&this).context.request_id);

                    (&this).context.shared_working.suspendable_control.
                        stopped_notification_done = true;
                    break;
                default:
                    assert(false);
            }

            if ( suspendable_control.notifyAndCheckStateChange!(Request)(
                (&this).context, notification) )
            {
                // The user used the controller in the notifier callback
                state_changed_in_notifier = true;
            }
        }

        return state_changed_in_notifier;
    }
}

///
unittest
{
    // Example request struct with RequestCore mixed in
    struct ExampleRequest
    {
        mixin ExampleRequestCore!();
    }

    // Required by SuspendableRequestControllerFiber
    enum MessageType
    {
        Suspend,
        Resume,
        Stop,
        Ack
    }

    // (Partial) request implementation, to be instantiated from the request's
    // handler function.
    scope class ExampleRequestImpl
    {
        import swarm.neo.util.MessageFiber;
        import swarm.neo.request.RequestEventDispatcher;
        import swarm.neo.connection.RequestOnConnBase;

        private RequestOnConn.EventDispatcherAllNodes conn;
        private ExampleRequest.Context* context;
        private MessageFiber controller_fiber;
        private RequestEventDispatcher request_event_dispatcher;

        public this ( RequestOnConn.EventDispatcherAllNodes conn,
            ExampleRequest.Context* context )
        {
            this.conn = conn;
            this.context = context;
        }

        // Assuming conneciton, initialisation, etc are complete...
        public void handle ( )
        {
            this.controller_fiber =
                new MessageFiber(&this.controllerFiberMethod, 64 * 1024);
            this.controller_fiber.start();

            // You'd typically also have a second fiber to handle reading or
            // writing from/to the node.

            this.request_event_dispatcher.eventLoop(this.conn);
            assert(this.controller_fiber.finished());
        }

        private void controllerFiberMethod ( )
        {
            SuspendableRequestControllerFiber!(ExampleRequest, MessageType)
                controller;
            controller.handle(this.conn, this.context,
                &this.request_event_dispatcher, this.controller_fiber);

            // Perform any logic here which should occur when the request has
            // stopped on all nodes (as initialised by the user via the
            // controller). For example, you may wish to abort the reader/writer
            // fiber.
        }
    }
}

/*******************************************************************************

    Data required by suspendableRequestConnector, SuspendableRequestInitialiser,
    and SuspendableController, to be placed in the request's shared working data
    (the field must be named suspendable_control).

*******************************************************************************/

public struct SuspendableRequestSharedWorkingData
{
    import swarm.neo.connection.RequestOnConnBase;

    /// Custom fiber resume code, used when the request handling fiber is
    /// resumed by the controller.
    public enum Signal
    {
        StateChangeRequested = 1
    }

    /// Enum of possible desired states of the request.
    private enum DesiredState
    {
        None,
        Running,
        Suspended,
        Stopped
    }

    /// Desired state of the request, as set by the user API.
    public DesiredState desired_state = DesiredState.Running;

    /***************************************************************************

        The number of handlers that are currently in the process of sending a
        control message to the node or waiting for an acknowledgement message
        back from the node, after a state change was requested by the user.

        Using the controller to request changing the request state is possible
        if and only if this number is 0. Whenever this count reaches 0, the user
        notifier is called, because at that point all available nodes have
        acknowledged the change in the request's state.

    ***************************************************************************/

    public uint changing_state;

    /***************************************************************************

        The number of nodes which are currently ready to handle state change
        messages. A node is not ready for state changes if the connection is not
        established or an error status code was returned.

        If this counter is 0, then a user-requested state change takes immediate
        effect, as the desired state will be sent to the node as part of the
        request setup (i.e. as opposed to being sent as a state change message
        once the request is running).

    ***************************************************************************/

    public uint ready_for_state_change;

    /***************************************************************************

        Flag set when the user has been notified that the request has stopped on
        all nodes. The request implementation should check the value of this
        flag to avoid also sending a "finished normally" notification.

    ***************************************************************************/

    public bool stopped_notification_done;

    /***************************************************************************

        Helper method providing the standard message payload contents relating
        to the state of a suspendable request. To be called from the FillPayload
        policy instance of the Initialiser policy (e.g.
        SuspendableRequestInitialiser) of an AllNodesRequest.

        A single bool value is added to the payload, indicating to the node
        whether or not the request should be started in the suspended state.

        Params:
            payload = payload to add suspendable state information to

    ***************************************************************************/

    public void fillPayload ( RequestOnConnBase.EventDispatcher.Payload payload )
    {
        bool start_suspended = (&this).desired_state == DesiredState.Suspended;
        payload.addConstant(start_suspended);
    }

    /***************************************************************************

        Helper method to handle detection of changes (via the controller) to the
        desired request state during calling a notification delegate. (When
        a notification is made, control is passed to user code. In this context,
        the controller may be used freely. Thus, whenever a notification occurs
        and a state change is possible, we need to check for requested state
        changes after the notifier exits.)

        Params:
            Request = type of request to which notification pertains
            context = request context
            n = notification to send

        Returns:
            true if the desired state of the request has changed during the
            notification

    ***************************************************************************/

    public bool notifyAndCheckStateChange ( Request ) (
        Request.Context* context, Request.Notification n )
    {
        auto desired_state_before_notify = (&this).desired_state;
        Request.notify(context.user_params, n);
        return desired_state_before_notify != (&this).desired_state;
    }

    /***************************************************************************

        Should be called when all active connections of a suspendable all-nodes
        request have been successfully initialised. (The usual location for this
        is at the start of the Handler policy, which is called immediately after
        initialisation is complete.)

        If the started notification has not already been called for this
        request, calls it and detects changes (via the controller) to the
        desired request state during calling the notification delegate. (When
        a notification is made, control is passed to user code. In this context,
        the controller may be used freely. Thus, whenever a notification occurs
        and a state change is possible, we need to check for requested state
        changes after the notifier exits.)

        Params:
            Request = type of request to which notification pertains
            context = request context

        Returns:
            true if the tarted notification was called and the desired state of
            the request changed during the notification

    ***************************************************************************/

    public bool allInitialised ( Request ) ( Request.Context* context )
    {
        auto desired_state_before_notify = (&this).desired_state;

        if ( context.shared_working.all_nodes.allInitialised!(Request)(context) )
            return desired_state_before_notify != (&this).desired_state;

        return false;
    }
}

/*******************************************************************************

    Template mixin containing boolerplate required by usage examples in this
    module.

*******************************************************************************/

private template ExampleRequestCore ( )
{
    import swarm.neo.client.mixins.RequestCore;
    import ocean.core.SmartUnion;

    // Required by RequestCore
    static immutable ubyte RequestCode = 0;
    static immutable ubyte RequestVersion = 0;

    // Required by RequestCore
    struct Args
    {
        // Dummy
    }

    union NotificationUnion
    {
        import swarm.neo.client.NotifierTypes;

        // Required by RequestCore
        RequestNodeUnsupportedInfo unsupported;

        // Required by allNodesRequestDisconnected()
        RequestNodeExceptionInfo node_disconnected;

        // Required by SuspendableController
        RequestInfo suspended;
        RequestInfo resumed;
        RequestInfo stopped;
    }

    // Required by RequestCore
    alias SmartUnion!(NotificationUnion) Notification;

    // Required by RequestCore
    alias void delegate ( Notification, Args ) Notifier;

    /***************************************************************************

        Request internals.

    ***************************************************************************/

    // Required by RequestCore
    private struct SharedWorking
    {
        // Required by AllNodesRequestInitialiser
        AllNodesRequestSharedWorkingData all_nodes;

        // Required by SuspendableRequestInitialiser etc
        SuspendableRequestSharedWorkingData suspendable_control;
    }

    // Required by RequestCore
    private struct Working
    {
        // Dummy
    }

    /***************************************************************************

        Request core. Mixes in the types `NotificationInfo`, `Notifier`,
        `Params`, `Context` plus the static constants `request_type` and
        `request_code`.

    ***************************************************************************/

    mixin RequestCore!(RequestType.AllNodes, RequestCode, RequestVersion,
        Args, SharedWorking, Working, Notification);
}

