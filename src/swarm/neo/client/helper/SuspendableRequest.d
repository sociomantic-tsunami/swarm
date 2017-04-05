/*******************************************************************************

    Helper struct for client-side suspendable requests which behave as follows:
        * Operate on all nodes.
        * Receive a stream of data, broken down into individual messages.
        * The stream can be suspended, resumed, and stopped by the user. These
          actions are known as "state changes".
        * While a state change is in progress, the user is unable to request
          another state change.
        * State changes are initiated by the user via a "controller" -- an
          interface to the active request, allowing it to be controlled while in
          progress.

    The struct handles all state change logic and communication with the node
    (on a per-request-on-conn basis). Request specifics such as codes and
    messages sent back and forth between the client and node are left
    deliberately abstract and must be provided by the request implementation
    which uses this helper.

    Each request-on-conn should have an instance of SuspendableRequest. The
    request's shared working data should contain an instance of the nested
    struct SuspendableRequest.SharedWorking.

    A note about the state handling methods:

    As control is sometimes given over to the caller, via the delegates that
    these methods use, it is possible that the user may have the opportunity to
    use the request controller while a method of SuspendableRequest is in
    progress. This possibility is handled, internally, by remembering the
    desired state at the beginning of the method and checking whether it's
    changed.

    Copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.client.helper.SuspendableRequest;

/// ditto
struct SuspendableRequest
{
    import ocean.transition;
    import swarm.neo.client.RequestOnConn;
    import swarm.neo.request.Command;

    /***************************************************************************

        Shared working data required for a suspendable request. An instance of
        this struct should be placed in your request's shared working data
        struct, where it is accessible to all request-on-conns of the request.

        All fields of this struct pertain to the request, not to any individual
        request-on-conn!

    ***************************************************************************/

    public static struct SharedWorking
    {
        /***********************************************************************

            Possible states of the request.

        ***********************************************************************/

        public enum RequestState
        {
            None,
            Running,
            Suspended,
            Stopped
        }

        public RequestState desired_state = RequestState.Running;

        /***********************************************************************

            The number of request-on-conns that are currently waiting for an
            acknowledgement message from the node after the request was started
            or its state changed. Changing the request state is possible if and
            only if this number is 0.

        ***********************************************************************/

        private uint waiting_for_ack_count;

        /***********************************************************************

            The number of request-on-conns which have successfully initialised
            the request (and are thus ready to send state change messages to the
            node).

        ***********************************************************************/

        private uint initialised_count;

        /***********************************************************************

            Set to true when the request has been successfully initialised on
            all active request-on-conns for the first time.

        ***********************************************************************/

        private bool first_initialisation;

        /***********************************************************************

            Changes the desired state to that specified, if it is currently
            possible to change the request's state (i.e. all request-on-conns
            have initialised the request and are not waiting for an ACK for a
            previous state change).

            Sets the desired state flag and resumes any request-on-conn fibers
            which are suspended, via the provided delegate (which should resume
            the fiber with a predetermined control message so that in the fiber
            the resumed suspend() call returns that message).

            If one or more connections are not ready to change state, the
            control change does not occur. A connection is ready to change the
            request state unless the handler is currently waiting for an
            acknowledgement message when beginning the request or changing its
            state.

            Params:
                new_state = desired state
                begin_state_change = delegate called when the state change may
                    be initiated. The delegate must resume any handler fibers
                    which are suspended, passing a predetermined control message
                    flag to the fiber via the return value of suspend()
                state_changed = delegate called when no request-on-conns are
                    ready to change state. The delegate should notify the user
                    that the state change has been carried out. (The reason for
                    this behaviour if no request-on-conns are ready is that the
                    the request will be initialised in the desired state, when
                    the connection is ready. See initialiseRequest().)

            Returns:
                true if the state change has been accepted and will be sent to
                all active nodes, false if one or more connections is already in
                the middle of changing state

        ***********************************************************************/

        public bool setDesiredState ( RequestState new_state,
            void delegate ( ) begin_state_change, void delegate ( ) state_changed )
        {
            // It's illegal to change the state while still waiting for an ACK
            // on the last state change.
            if ( this.waiting_for_ack_count )
                return false;

            this.desired_state = new_state;

            // If one or more connections are ready to send a state change
            // message to the node, we initiate this.
            if ( this.initialised_count )
            {
                begin_state_change();
            }
            // If no connections are ready to send state change messages (i.e. 
            // the request has not begun on those connections), the state change
            // essentially occurs immediately (without the need for node
            // contact).
            else
            {
                state_changed();
            }

            return true;
        }
    }

    /***************************************************************************

        Note: all subsequent members of this struct pertain to an individual
        request-on-conn.

    ***************************************************************************/

    /***************************************************************************

        Event dispatcher for this request-on-conn.

    ***************************************************************************/

    private RequestOnConn.EventDispatcherAllNodes conn;

    /***************************************************************************

        Pointer to the shared working data for this request.

    ***************************************************************************/

    private SharedWorking* shared_working;

    /***************************************************************************

        Set when the request has been successfully initialised on this
        connection (in initialiseRequest()). State changes are allowed after
        this point.

        (The actual purpose of this flag is for setNotReadyForStateChange() to
        tell whether shared_working.initialised_count was already
        decremented.)

    ***************************************************************************/

    private bool ready_for_state_change;

    /***************************************************************************

        Enum defining the states in which a request-on-conn of a suspendable
        request may be.

    ***************************************************************************/

    public enum State
    {
        /// Waiting for the connection to come up
        EstablishingConnection,

        /// Initialising the request on this connection
        Initialising,

        /// In the main loop of receiving data from the node
        Receiving,

        /// Sending a message to the node to initiate a state change
        RequestingStateChange,

        /// Request finished on this connection
        Exit
    }

    /***************************************************************************

        Enum defining the actions which a message received from the node may
        trigger.

    ***************************************************************************/

    public enum ReceivedMessageAction
    {
        /// The received message was of an unknown type
        Undefined,

        /// The received message contained an acknowledgement from the node that
        /// a requested state change has taken effect
        Ack,

        /// The received message indicates that the request should end on this
        /// connection
        Exit,

        /// The received message indicates that no action need be taken
        Continue
    }

    /***************************************************************************

        Alias for a delegate which handles a received message and returns a
        decision on what action need be taken.

    ***************************************************************************/

    private alias ReceivedMessageAction delegate ( Const!(void)[] received )
        ReceivedMessageDg;

    /***************************************************************************

        Initialises this instance.

        Params:
            conn = event dispatcher for this request-on-conn
            shared_working = pointer to the shared working data for this request

    ***************************************************************************/

    public void initialise ( RequestOnConn.EventDispatcherAllNodes conn,
        SharedWorking* shared_working )
    in
    {
        assert(conn !is null);
        assert(shared_working !is null);
    }
    body
    {
        this.conn = conn;
        this.shared_working = shared_working;
    }

    /***************************************************************************

        Waits for the connection to be established. (May exit immediately, if
        the connection is already up.)

        Params:
            resumed_by_controller = delegate called to determine whether the
                call to conn.waitForReconnect() exited because the
                request-on-conn fiber was resumed by the controller (at the
                user's behest). In this case, we usually continue trying to
                connect.

        Returns:
            the next state to enter (normally Initialising; may also be Exit, if
            the user instructed the request to stop, via the controller)

    ***************************************************************************/

    public State establishConnection (
        bool delegate ( int resume_code ) resumed_by_controller )
    {
        while ( true )
        {
            int resume_code = this.conn.waitForReconnect();
            if ( resumed_by_controller(resume_code) )
            {
                if ( this.shared_working.desired_state ==
                    this.shared_working.desired_state.Stopped )
                    // The user requested to stop this request, so we don't
                    // need to wait for a reconnection any more.
                    return State.Exit;
            }
            else
            {
                switch ( resume_code )
                {
                    case conn.FiberResumeCodeReconnected:
                    case 0: // The connection is already up
                        return State.Initialising;

                    default:
                        assert(false,
                            "Unexpected fiber resume code when connecting");
                }
            }
        }

        assert(false);
    }

    /***************************************************************************

        Initialises the request on this connection, sending the required
        messages (e.g. the request code, channel name, etc) to the node and
        receiving a status code in response.

        Params:
            set_payload = delegate which should set the message payload to send
                to the node to initialise the request
            received_status_ok = delegate which determines whether the status
                code received from the node means that the request should
                continue or exit (true = continue, false = exit)
            first_initialisation = delegate which is called when the request is
                successfully initialised for the first time on all active
                connections. (Presumably the user should be informed of this.)

        Returns:
            the next state to enter (normally Receiving; may be Exit, if the
            status code received from the node indicated an error; may be
            RequestingStateChange, if the user requested a state change in one
            of the delegates which is called)

    ***************************************************************************/

    public State initialiseRequest (
        void delegate ( RequestOnConn.EventDispatcherAllNodes.Payload ) set_payload,
        bool delegate ( StatusCode ) received_status_ok,
        void delegate ( ) first_initialisation )
    in
    {
        assert(!this.ready_for_state_change);
    }
    out ( state )
    {
        if (state == state.Exit)
            assert(!this.ready_for_state_change);
        else
            assert(this.ready_for_state_change);
    }
    body
    {
        // Memorize the state that will be sent to the node in order to detect a
        // requested state change in one of the delegates.
        auto last_state = this.shared_working.desired_state;

        try
        {
            // establishConnection() should guarantee we're already connected
            assert(this.conn.waitForReconnect() == 0);

            // We know that the connection is up, so from now on we count this
            // request-on-conn as being in the state of waiting for an
            // acknowledgement from the node (the status code, in this case).
            this.shared_working.waiting_for_ack_count++;

            // Send request initialisation data to the node
            this.conn.send(set_payload);

            // Receive status from node and stop the request if not Ok
            auto status = this.conn.receiveValue!(StatusCode)();
            if ( !received_status_ok(status) )
            {
                return State.Exit;
            }
        }
        finally
        {
            // After receiving the status (whether an error or OK), this
            // request-on-conn is no longer counted as waiting for an ack.
            assert(this.shared_working.waiting_for_ack_count);
            --this.shared_working.waiting_for_ack_count;
        }

        // Now we're ready to receive records from the node or to handle state
        // change requests from the user via the controller.
        this.setReadyForStateChange();

        // Handle first initialisation notification
        if ( !this.shared_working.first_initialisation &&
            !this.shared_working.waiting_for_ack_count )
        {
            this.shared_working.first_initialisation = true;
            first_initialisation();
        }

        // Return the next state, handling the case where the desired state of
        // the request has changed since the start of this method.
        return (last_state == this.shared_working.desired_state)
            ? State.Receiving
            : State.RequestingStateChange;
    }

    /***************************************************************************

        Receives incoming messages from the node.

        Params:
            handle_received_message = delegate to which received messages are
                passed. The return value determines whether the request
                continues receiving, begins changing state, or exits.

        Returns:
            the next state to enter (normally Receiving; may be
            RequestingStateChange or Exit)

        Throws:
            ProtocolError, if handle_received_message returns Undefined or Ack
            (it's important that the caller does not swallow this exception)

    ***************************************************************************/

    public State receive ( ReceivedMessageDg handle_received_message )
    {
        // Memorize the current desired state in order to detect a requested
        // state change in the delegate.
        auto last_state = this.shared_working.desired_state;
        ReceivedMessageAction msg_action;
        int resume_code = this.conn.receiveAndHandleEvents(
            ( in void[] received )
            {
                msg_action = handle_received_message(received);
            }
        );

        if ( resume_code < 0 ) // Fiber resumed due to received data
        {
            with ( ReceivedMessageAction ) switch ( msg_action )
            {
                case Exit:
                    return State.Exit;
                case Continue:
                    break;
                default:
                    throw this.conn.shutdownWithProtocolError(
                        "Unexpected message type while receiving");
            }
        }

        return (last_state == this.shared_working.desired_state)
            ? State.Receiving
            : State.RequestingStateChange;
    }

    /***************************************************************************

        Sends a request state change message to the node and waits for the
        acknowledgement, handling records arriving in the mean time, as normal.

        If the node connection breaks while sending the state change message or
        receiving the acknowledgement, the state change was successful because
        the request-on-conn will be restarted with the requested state.

        Params:
            control_msg = message to send to the node to initiate the state
                change
            handle_received_message = delegate to which messages received while
                changing state are passed. The return value determines whether
                the request continues receiving or exits.
            state_changed = delegate called when the state change has been
                carried out

        Returns:
            the next state to enter (normally Receiving; may be Exit, if the
            desired state is Stopped; may be RequestingStateChange again, if the
            desired state changed while calling the state_changed delegate)

        Throws:
            ProtocolError, if handle_received_message returns an unexpected
            value (see sendStateChangeMessage() and waitForAck()).
            (It's important that the caller does not swallow this exception.)

    ***************************************************************************/

    public State requestStateChange ( ubyte control_msg,
        ReceivedMessageDg handle_received_message, void delegate ( ) state_changed )
    {
        this.shared_working.waiting_for_ack_count++;

        // Memorize the state that will be sent to the node in order to detect a
        // requested state change in the state_change delegate.
        auto signaled_state = this.shared_working.desired_state;

        try
        {
            // If throwing, set this request not ready for a state change
            // *before* calling state_change() in the `finally` clause, where
            // the user may request a state change.
            scope (failure) this.setNotReadyForStateChange();

            if ( !this.sendStateChangeMessage(control_msg, handle_received_message) )
                return State.Exit;
            if ( !this.waitForAck(handle_received_message) )
                return State.Exit;
        }
        finally
        {
            assert(this.shared_working.waiting_for_ack_count);
            if ( !--this.shared_working.waiting_for_ack_count )
            {
                // If this was the last request-on-conn waiting for the
                // acknowledgement, inform the caller that the requested control
                // message has taken effect.
                state_changed();
            }
        }

        // Handle further state change requests that happened during this
        // method.
        if ( this.shared_working.desired_state != signaled_state )
            return State.RequestingStateChange;

        return (signaled_state == signaled_state.Stopped)
            ? State.Exit
            : State.Receiving;
    }

    /***************************************************************************

        Sends a request state change message to the node and handles records
        which arrive in the mean time, as normal.

        Params:
            control_msg = message to send to the node to initiate the state
                change
            handle_received_message = delegate to which messages received while
                changing state are passed. The return value determines whether
                the request continues or exits.

        Returns:
            true to continue changing state, false to exit

        Throws:
            ProtocolError, if handle_received_message returns Undefined or Ack
            (it's important that the caller does not swallow this exception)

    ***************************************************************************/

    private bool sendStateChangeMessage ( ubyte control_msg,
        ReceivedMessageDg handle_received_message )
    {
        bool send_interrupted;
        do
        {
            // Though the controller may be called at this point (via the call
            // to handle_received_message()), we do not check for state changes
            // as the controller enforces that a state change may not be
            // requested while the last is in progress. (See
            // SharedWorking.setDesiredState().)
            ReceivedMessageAction msg_action;
            send_interrupted = false;
            this.conn.sendReceive(
                ( in void[] received )
                {
                    send_interrupted = true;
                    msg_action = handle_received_message(received);
                },
                ( conn.Payload payload )
                {
                    payload.add(control_msg);
                }
            );

            if ( !send_interrupted ) // The control message was sent
                break;

            with ( ReceivedMessageAction ) switch ( msg_action )
            {
                case Exit:
                    return false;
                case Continue:
                    break;
                default:
                    throw this.conn.shutdownWithProtocolError(
                        "Unexpected message type while sending state change");
            }
        }
        while ( send_interrupted );

        return true;
    }

    /***************************************************************************

        Waits for the acknowledgement of a state change and handles records
        which arrive in the mean time, as normal.

        Params:
            handle_received_message = delegate to which messages received while
                changing state are passed. The return value determines whether
                the request continues or exits.

        Returns:
            true to continue changing state, false to exit

        Throws:
            ProtocolError, if handle_received_message returns Undefined (it's
            important that the caller does not swallow this exception)

    ***************************************************************************/

    private bool waitForAck (
        ReceivedMessageDg handle_received_message )
    {
        bool ack;
        do
        {
            ReceivedMessageAction msg_action;
            int resume_code = this.conn.receiveAndHandleEvents(
                ( in void[] received )
                {
                    msg_action = handle_received_message(received);
                }
            );
            assert(resume_code <= 0, "Fiber unexpectedly resumed");

            with ( ReceivedMessageAction ) switch ( msg_action )
            {
                case Exit:
                    return false;
                case Continue:
                    break;
                case Ack:
                    ack = true;
                    break;
                default:
                    throw this.conn.shutdownWithProtocolError(
                        "Unexpected message type while awaiting ACK");
            }
        }
        while ( !ack );

        return true;
    }

    /***************************************************************************

        Flags this request-on-conn as ready to handle state changes and
        increments the global (for this request) counter of the number of
        request-on-conns which are ready for state changes.

    ***************************************************************************/

    private void setReadyForStateChange ( )
    {
        this.ready_for_state_change = true;
        this.shared_working.initialised_count++;
    }

    /***************************************************************************

        If this request-on-conn is flagged as ready for state changes, sets it
        as not ready and decrements the global (for this request) counter of the
        number of request-on-conns which are ready for state changes.

        This method is public as it needs to be called from the request-on-conn
        handler when the request state machine throws or exits.

        (TODO: I wonder if this can be reworked so that it doesn't need to be
        public.)

    ***************************************************************************/

    public void setNotReadyForStateChange ( )
    {
        if ( this.ready_for_state_change )
        {
            assert(this.shared_working.initialised_count);
            this.shared_working.initialised_count--;
            this.ready_for_state_change = false;
        }
    }
}
