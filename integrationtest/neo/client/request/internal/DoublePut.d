/*******************************************************************************

    Internal implementation of the client's DoublePut request.

    Copyright:
        Copyright (c) 2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module integrationtest.neo.client.request.internal.DoublePut;

import ocean.transition;

/*******************************************************************************

    DoublePut request implementation.

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

public struct DoublePut
{
    import integrationtest.neo.common.DoublePut;
    import integrationtest.neo.client.request.DoublePut;
    import integrationtest.neo.common.RequestCodes;
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
        /// Enum indicating the ways in which the request may end.
        public enum NodeState
        {
            None,
            Failure,    // Default value; unknown error (presumably in client)
            Error,      // Node or I/O error
            Success     // Put record
        }

        /// The way in which the request ended on each node. Used by the
        /// finished notifier to decide what kind of notification (if any) to
        /// send to the user.
        public NodeState[2] node_state;

        /// The index of the next node to be contacted. Used by nextNodeIndex().
        private size_t next_node_index;

        /***********************************************************************

            Returns:
                the index of the next node to be contacted. Should be called at
                the start of the handler function, in order to find out which
                node the particular call of the handler should contact.

        ***********************************************************************/

        public size_t nextNodeIndex ( )
        {
            scope ( exit )
                this.next_node_index++;
            return this.next_node_index;
        }
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

    mixin RequestCore!(RequestType.MultiNode, RequestCode.DoublePut, 0, Args,
        SharedWorking, Working, Notification);

    /***************************************************************************

        Request handler. Called from RequestOnConn.runHandler().

        Params:
            use_node = delegate to be called to allow the request to send /
                receive data over a specific connection. May be called as many
                times as required by the request
            start_request_on_new_conn = delegate to be called to call this
                handler again in a new RequestOnConn instance
            context_blob = untyped chunk of data containing the serialized
                context of the request which is to be handled

    ***************************************************************************/

    public static void handler ( UseNodeDg use_node,
        void delegate ( ) start_request_on_new_conn, void[] context_blob )
    {
        auto context = DoublePut.getContext(context_blob);
        auto node_idx = context.shared_working.nextNodeIndex();
        auto state = &context.shared_working.node_state[node_idx];
        *state = SharedWorking.NodeState.Failure;

        // In a real client, you'd have to have some way for a request to decide
        // which node to operate on. In this simple example, we just hard-code
        // the nodes' addresses/ports.
        ushort[2] ports = [10_000, 10_010];
        AddrPort node;
        node.setAddress("127.0.0.1");
        node.port = ports[node_idx];

        // If the selected node is the first, start the request on the second.
        if ( node_idx == 0 )
            start_request_on_new_conn();

        // Send to the selected node.
        scope dg = ( RequestOnConn.EventDispatcher conn )
        {
            try
            {
                // Send request info to node
                conn.send(
                    ( conn.Payload payload )
                    {
                        payload.add(DoublePut.cmd.code);
                        payload.add(DoublePut.cmd.ver);
                        payload.add(context.user_params.args.key);
                        payload.addArray(context.user_params.args.value);
                    }
                );
                conn.flush();

                // Receive supported status from node
                auto supported = conn.receiveValue!(SupportedStatus)();
                if ( !DoublePut.handleSupportedCodes(supported, context,
                    conn.remote_address) )
                {
                    // Global codes (not supported / version not supported)
                    *state = SharedWorking.NodeState.Error;
                }
                else
                {
                    // Receive result code from node
                    auto result = conn.receiveValue!(StatusCode)();

                    with ( RequestStatusCode ) switch ( result )
                    {
                        case Succeeded:
                            *state = SharedWorking.NodeState.Success;
                            break;

                        case Error:
                            *state = SharedWorking.NodeState.Error;

                            // The node returned an error code. Notify the user.
                            Notification n;
                            n.node_error = RequestNodeInfo(
                                context.request_id, conn.remote_address);
                            DoublePut.notify(context.user_params, n);
                            break;

                        default:
                            // Treat unknown codes as internal errors.
                            goto case Error;
                    }
                }
            }
            catch ( IOError e )
            {
                // A connection error occurred. Notify the user.
                *state = SharedWorking.NodeState.Error;

                Notification n;
                n.node_disconnected = RequestNodeExceptionInfo(
                    context.request_id, conn.remote_address, e);
                DoublePut.notify(context.user_params, n);
            }
        };
        use_node(node, dg);
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
        auto context = DoublePut.getContext(context_blob);

        uint success_count;
        foreach ( state; context.shared_working.node_state )
            if ( state == state.Success )
                success_count++;

        Notification n;
        switch ( success_count )
        {
            case 0:
                n.failed = NoInfo();
                break;
            case 1:
                n.partial_success = NoInfo();
                break;
            case 2:
                n.succeeded = NoInfo();
                break;
            default:
                assert(false);
        }

        DoublePut.notify(context.user_params, n);
    }
}
