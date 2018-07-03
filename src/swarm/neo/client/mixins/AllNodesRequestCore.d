/*******************************************************************************

    Helpers encapsulating core behaviour for all-nodes requests.

    The following helpers exist in this module:

    * AllNodesRequest: struct template encapsulating the core logic for handling
      an all-nodes request. This is broken down into the following steps:
        * Connection: ensuring a connection to the node is established.
        * Initialisation: sending of a message containing all information
          required by the node to start handling the request; waiting for and
          validating the status code sent back by the node.
        * Handling: the main logic of the request.

      The behaviours at each stage are defined by a set of policy instances (of
      types defined by template arguments of AllNodesRequest).

    * createAllNodesRequest: helper function to instantiate AllNodesRequest.
      Using this function allows the compiler to infer the template arguments of
      AllNodesRequest from the types of the function arguments.

    * allNodesRequestConnector: function providing the standard logic for
      connecting a request-on-conn of an all-nodes request. To be called from
      the Connector policy instance of an AllNodesRequest.

    * AllNodesRequestInitialiser: struct template encapsulating the logic for
      initialising an all-nodes request. This is broken down into the following
      steps:
        * Sending a message containing all information required by the node to
          start handling the request.
        * Waiting for the status code (a single ubyte) sent back by the node.
        * Validating the status code.

      The behaviours at each stage are defined by a set of policy instances (of
      types defined by template arguments of AllNodesRequestInitialiser).

    * createAllNodesRequestInitialiser: helper function to instantiate
      AllNodesRequestInitialiser. Using this function allows the compiler to
      infer the template arguments of AllNodesRequestInitialiser from the types
      of the function arguments.

    * AllNodesRequestSharedWorkingData: struct encapsulating shared working data
      required by AllNodesRequestInitialiser. If using the initialiser provided
      in this module, a field of type AllNodesRequestSharedWorkingData, named
      all_nodes must be added to the request's shared working data struct.

    Copyright: Copyright (c) 2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.neo.client.mixins.AllNodesRequestCore;

import swarm.neo.client.RequestOnConn;
import swarm.neo.client.NotifierTypes;

/*******************************************************************************

    Struct template encapsulating the core logic for handling a single request-
    on-conn of an all-nodes request. This is broken down into the following
    steps:
        * Connection: ensuring a connection to the node is established.
        * Initialisation: sending of a message containing all information
          required by the node to start handling the request; waiting for and
          validating the status code sent back by the node.
        * Handling: the main logic of the request.

    The behaviours at each stage are defined by a set of policy instances, the
    types of which are defined by template arguments.

    Params:
        Request = type of the request being handled
        Connector = type of policy instance to be called to perform connection
            establishment. Should return true to continue with the request or
            false to abort.
        Disconnected = type of policy instance to be called when an I/O error
            causes the connection to the node to break. Should perform behaviour
            such as notifying the user and resetting any state for the request-
            on-conn (e.g. any working data).
        Initialiser = type of policy instance to handle initialisation of the
            request on this connection (i.e. sending the initial payload and
            handling the corresponding status code from the node). This policy
            is expected to provide two functions:
                * initialise(): handles the actual initialisation process.
                * reset(): should reset any state required for initialisation to
                  begin again. (Called after the handler exits, whether due to
                  an error or not.)
        Handler = typoe of policy instance to be called to handle the main logic
            of the request.

*******************************************************************************/

public struct AllNodesRequest ( Request, Connector, Disconnected, Initialiser,
    Handler )
{
    import swarm.neo.client.RequestOnConn;
    import ocean.io.select.selector.EpollException;
    import ocean.io.select.protocol.generic.ErrnoIOException;

    /// Policy object for handling connection establishment.
    private Connector connector;

    /// Policy object called upon disconnection.
    private Disconnected disconnected;

    // Policy object for handling initialisation, once connected.
    private Initialiser initialiser;

    /// Policy object for handling the main request logic, once initialised.
    private Handler handler;

    /// Request-on-conn event dispatcher.
    private RequestOnConn.EventDispatcherAllNodes conn;

    /// Request context.
    private Request.Context* context;

    /***************************************************************************

        Performs the logic of connection establishment, request initialisation,
        and request handling, as specified by the policy objects.

    ***************************************************************************/

    public void run ( )
    {
        bool reconnect;
        do
        {
            reconnect = false;

            try
            {
                if ( !(&this).connector() )
                    return; // request aborted

                if ( !(&this).initialiser.initialise() )
                    return; // request aborted

                (&this).handler();
            }
            // Only retry in the case of a connection I/O error or error event
            // in epoll. Other errors indicate internal problems and should not
            // be retried.
            catch ( IOError e )
            {
                (&this).disconnected(e);
                reconnect = true;
            }
            catch ( EpollException e )
            {
                (&this).disconnected(e);
                reconnect = true;
            }
            finally
            {
                (&this).initialiser.reset();
            }
        }
        while ( reconnect );
    }
}

/*******************************************************************************

    Helper function to instantiate AllNodesRequest. Using this function allows
    the compiler to infer the template arguments of AllNodesRequest from the
    types of the function arguments.

    Params:
        Request = type of the request being handled
        Connector = type of policy instance to be called to perform connection
            establishment (see AllNodesRequest)
        Disconnected = type of policy instance to be called when an I/O error
            causes the connection to the node to break (see AllNodesRequest)
        Initialiser = type of policy instance to handle initialisation of the
            request on this connection (see AllNodesRequest)
        Handler = type of policy instance to be called to handle the main logic
            of the request (see AllNodesRequest)
        conn = request-on-conn event dispatcher to use for handling the request
        context = request context
        connector = instance of Connector policy
        disconnected = instance of Disconnected policy
        initialiser = instance of Initialiser policy
        handler = instance of Handler policy

    Returns:
        instance of AllNodesRequest constructed with the provided arguments

*******************************************************************************/

public AllNodesRequest!(Request, Connector, Disconnected, Initialiser, Handler)
    createAllNodesRequest ( Request, Connector, Disconnected, Initialiser, Handler )
    ( RequestOnConn.EventDispatcherAllNodes conn,
    Request.Context* context, Connector connector, Disconnected disconnected,
    Initialiser initialiser, scope Handler handler )
{
    return
        AllNodesRequest!(Request, Connector, Disconnected, Initialiser, Handler)
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
        private RequestOnConn.EventDispatcherAllNodes conn;
        private ExampleRequest.Context* context;

        public this ( RequestOnConn.EventDispatcherAllNodes conn,
            ExampleRequest.Context* context )
        {
            this.conn = conn;
            this.context = context;
        }

        // Instantiates an AllNodesRequest with dummy delegates passed as the
        // various policies.
        public void run ( )
        {
            Initialiser initialiser;
            auto request = createAllNodesRequest!(ExampleRequest)(
                this.conn, this.context, &this.connect, &this.disconnected,
                initialiser, &this.handle);
            request.run();
        }

        // Dummy policies...
        private bool connect ( )
        {
            return true;
        }

        private void disconnected ( Exception e ) { }

        private struct Initialiser
        {
            bool initialise ( )
            {
                return true;
            }

            void reset ( ) { }
        }

        private void handle ( ) { }
    }
}

/*******************************************************************************

    Helper function providing the standard logic for connecting a request-on-
    conn of an all-nodes request. To be called from the Connector policy
    instance of an AllNodesRequest.

    Suspends the specified request-on-conn until the connection is established.

    Params:
        conn = request-on-conn to suspend until the connection is established

    Returns:
        always true (indicates that the request should be initialised)

*******************************************************************************/

public bool allNodesRequestConnector (
    RequestOnConn.EventDispatcherAllNodes conn )
{
    auto resume_code = conn.waitForReconnect();
    switch ( resume_code )
    {
        case conn.FiberResumeCodeReconnected:
        case 0: // The connection is already up
            break;

        default:
            assert(false);
    }

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

        public this ( RequestOnConn.EventDispatcherAllNodes conn )
        {
            this.conn = conn;
        }

        // Method to be passed (as a delegate) as the Connector policy of
        // AllNodesRequest. Forwards to allNodesRequestConnector.
        private bool connect ( )
        {
            return allNodesRequestConnector(this.conn);
        }
    }
}

/*******************************************************************************

    Struct template encapsulating the core logic for initialising a single
    request-on-conn of an all-nodes request. Initialisation is defined as:
        * Sending a message containing all information required by the node to
          start handling the request.
        * Waiting for the status code (a single ubyte) sent back by the node.
        * Validating the status code.

    The behaviours at each stage are defined by a set of policy instances, the
    types of which are defined by template arguments.

    This struct is suitable for passing to AllNodesRequest as the Initialiser
    policy.

    Note that this initialiser requires a field named all_nodes, of type
    AllNodesRequestSharedWorkingData, to exist in the request's shared working
    data. The fields of this struct are used by the initialiser and should not
    be touched by other code.

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

public struct AllNodesRequestInitialiser ( Request, FillPayload,
    HandleStatusCode )
{
    import swarm.neo.client.RequestOnConn;
    import swarm.neo.connection.RequestOnConnBase;
    import swarm.neo.client.Connection;

    /// Connection event dispatcher.
    public RequestOnConn.EventDispatcherAllNodes conn;

    /// Request context.
    public Request.Context* context;

    /// Policy object for adding fields to the initial message payload.
    public FillPayload fill_payload;

    /// Policy object for handling the status code received from the node.
    public HandleStatusCode handle_status_code;

    /***************************************************************************

        Performs the logic of request initialisation. Called by
        AllNodesRequestHandler.

        Returns:
            true if initialisation succeeded for this request-on-conn, false to
            abort handling of the request on this connection

    ***************************************************************************/

    public bool initialise ( )
    {
        // establishConnection() should guarantee we're already connected
        assert((&this).conn.connection_status() == Connection.Status.Connected);

        auto all_nodes = &(&this).context.shared_working.all_nodes;

        // We know that the connection is up, so from now on we count this
        // request among those which the started notification depends on.
        all_nodes.initialising++;
        scope ( exit )
            all_nodes.initialising--;

        // Send request info to node
        (&this).conn.send(
            ( conn.Payload payload )
            {
                payload.add(Request.cmd.code);
                payload.add(Request.cmd.ver);
                (&this).fill_payload(payload);
            }
        );

        // Receive status from node and stop the request if not Ok
        auto status = conn.receiveValue!(ubyte)();
        if ( !(&this).handle_status_code(status) )
            return false;

        return true;
    }

    /***************************************************************************

        Called by AllNodesRequest to reset any state required for initialisation
        to begin again.

        (In this case, there is no state that needs resetting:
        AllNodesRequestSharedWorkingData.initialising is reset in the
        scope(exit) of initialise() and
        AllNodesRequestSharedWorkingData.called_started_notifier should never be
        reset because it must be called strictly once ever during the lifetime
        of the request.)

    ***************************************************************************/

    public void reset ( )
    {
    }
}

/*******************************************************************************

    Helper function to instantiate AllNodesRequestInitialiser. Using this
    function allows the compiler to infer the template arguments of
    AllNodesRequestInitialiser from the types of the function arguments.

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
        instance of AllNodesRequestInitialiser constructed with the provided
        arguments

*******************************************************************************/

public AllNodesRequestInitialiser!(Request, FillPayload, HandleStatusCode)
    createAllNodesRequestInitialiser ( Request, FillPayload,
    HandleStatusCode )
    ( RequestOnConn.EventDispatcherAllNodes conn,
    Request.Context* context, FillPayload fill_payload,
    HandleStatusCode handle_status_code )
{
    return
        AllNodesRequestInitialiser!(Request, FillPayload, HandleStatusCode)
        (conn, context, fill_payload, handle_status_code);
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

        // Instantiates an AllNodesRequestInitialiser with dummy delegates
        // passed as the various policies.
        public void run ( )
        {
            auto initialiser = createAllNodesRequestInitialiser!(ExampleRequest)(
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

    Data required by AllNodesRequestInitialiser, to be placed in the request's
    shared working data (the field must be named all_nodes).

*******************************************************************************/

public struct AllNodesRequestSharedWorkingData
{
    import swarm.neo.client.NotifierTypes;

    /***************************************************************************

        The number of request-on-conns that are currently in the process of
        initialising the request -- sending the initial payload and waiting for
        a status code back from the node.

        Used to decide when to send the started notification to the user.

    ***************************************************************************/

    private uint initialising;

    /***************************************************************************

        Flag set when the user's started notifier has been called. This is
        needed to ensure that this notification only occurs once. (Otherwise, it
        would be repeated if a connection died and was reestablished, for
        example.)

    ***************************************************************************/

    private bool called_started_notifier;

    /***************************************************************************

        Returns:
            the number of request-on-conns for this request which are in the
            process of initialising.

    ***************************************************************************/

    public uint num_initialising ( )
    {
        return (&this).initialising;
    }

    /***************************************************************************

        Should be called when all active connections of an all-nodes request
        have been successfully initialised. (The usual location for this is at
        the start of the Handler policy, which is called immediately after
        initialisation is complete.)

        If the started notification has not already been called for this
        request, calls it.

        Params:
            Request = type of request
            context = request context

        Returns:
            true if the notifier was called; false if it was called before

    ***************************************************************************/

    public bool allInitialised ( Request ) ( Request.Context* context )
    in
    {
        assert((&this).initialising == 0);
    }
    body
    {
        if ( (&this).called_started_notifier )
            return false;

        (&this).called_started_notifier = true;

        Request.Notification n;
        n.started = RequestInfo(context.request_id);
        Request.notify(context.user_params, n);
        return true;
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
