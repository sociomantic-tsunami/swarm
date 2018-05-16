/*******************************************************************************

    Helpers encapsulating core behaviour for suspendable all-nodes requests
    where records are sent in batches so suspending happens only in the client.

    The following helpers, building on top of the helpers in
    swarm.neo.client.mixins.AllNodesRequestCore, exist in this module:

    * BatchController: template mixin containing a class that implements
      the standard logic for a request controller accessible via the user API.
      Has public methods suspend(), resume(), and stop().

    * BatchRequestSharedWorkingData: struct encapsulating shared working
      data required by the helpers in this module. If using these helpers, a
      field of type BatchRequestSharedWorkingData, named
      suspendable_control must be added to the request's shared working data
      struct.

    * batchRequestConnector: function providing the standard logic for
      connecting a request-on-conn of an all-nodes batch request. To be called
      from the Connector policy instance of an AllNodesRequest.

    Copyright: Copyright (c) 2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.client.mixins.BatchRequestCore;

import swarm.neo.client.RequestOnConn;
import swarm.neo.client.mixins.AllNodesRequestCore;

/*******************************************************************************

    Helper function providing the standard logic for connecting a request-on-
    conn of a suspendable all-nodes batch request. To be called from the
    Connector policy instance of an AllNodesRequest.

    Suspends the specified request-on-conn until the connection is established
    or the user instructs the request to stop.

    Params:
        conn = request-on-conn to suspend until the connection is established

    Returns:
        true (indicates that the request should be initialised) on successful
        connection; false (indicates that the request should be aborted) if the
        user wishes to stop the request

*******************************************************************************/

public bool batchRequestConnector ( RequestOnConn.EventDispatcherAllNodes conn )
{
    while (true)
    {
        switch (conn.waitForReconnect())
        {
            case conn.FiberResumeCodeReconnected:
            case 0: // The connection is already up.
                return true;

            case BatchRequestSharedWorkingData.Signal.Resume:
                break; // Ignore this signal.

            case BatchRequestSharedWorkingData.Signal.Stop:
                // The user requested to stop this request, so we don't
                // need to wait for a reconnection any more.
                return false;

            default:
                assert(false);
        }
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
        // AllNodesRequest. Forwards to batchRequestConnector.
        private bool connect ( )
        {
            return batchRequestConnector(this.conn);
        }
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

*******************************************************************************/

public template BatchController ( Request, IController )
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

            Suspends passing the received records to the user notifier.

            Returns:
                true because this controller function can always be used

        ***********************************************************************/

        public bool suspend ( )
        {
            Request.getContext(this.request_controller.context_blob)
                .shared_working.suspendable_control.suspended = true;
            return true;
        }

        /***********************************************************************

            Resumes passing the received records to the user notifier.

            Returns:
                true because this controller function can always be used

        ***********************************************************************/

        public bool resume ( )
        {
            Request.getContext(this.request_controller.context_blob)
                .shared_working.suspendable_control.suspended = false;
            this.request_controller.resumeSuspendedHandlers(
                BatchRequestSharedWorkingData.Signal.Resume);
            return true;
        }

        /***********************************************************************

            Tells the nodes to cleanly end the request.
            Records that have already been received from the node will still be
            passed to the user. It is possible to use `suspend` and `resume`.

            Returns:
                true because this controller function can always be used

        ***********************************************************************/

        public bool stop ( )
        {
            with (Request.getContext(this.request_controller.context_blob)
                .shared_working.suspendable_control)
            {
                if (!stopped)
                {
                    stopped = true;
                    this.request_controller.resumeSuspendedHandlers(
                        BatchRequestSharedWorkingData.Signal.Stop);
                }
            }
            return true;
        }
    }
}

///
unittest
{
    // Example request struct with RequestCore and BatchController mixed in
    struct ExampleRequest
    {
        mixin ExampleRequestCore!();

        // Required by BatchController
        interface IController
        {
            bool suspend ( );
            bool resume ( );
            bool stop ( );
        }

        mixin BatchController!(ExampleRequest, IController);
    }
}

/*******************************************************************************

    Data required by BatchController, to be placed in the request's shared
    working data (the field must be named suspendable_control).

*******************************************************************************/

public struct BatchRequestSharedWorkingData
{
    import swarm.neo.connection.RequestOnConnBase;

    /// Custom fiber resume code, used when the request handling fiber is
    /// resumed by the controller.
    public enum Signal: uint
    {
        Resume = 1,
        Stop
    }

    /// `true` while the request is suspended.
    public bool suspended = false;

    /// `true` when stopping the request has been requested with the controller.
    public bool stopped = false;
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

        // Required by BatchController
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

        // Required by BatchRequestInitialiser etc
        BatchRequestSharedWorkingData suspendable_control;
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

