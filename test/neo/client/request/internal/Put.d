/*******************************************************************************

    Internal implementation of the client's Put request.

    Copyright:
        Copyright (c) 2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module test.neo.client.request.internal.Put;

import ocean.transition;

/*******************************************************************************

    Put request implementation.

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

public struct Put
{
    import test.neo.common.Put;
    import test.neo.client.request.Put;
    import test.neo.common.RequestCodes;
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
        public enum Result
        {
            Failure,    // Default value; unknown error (presumably in client)
            Error,      // Node or I/O error
            Put         // Put record
        }

        /// The way in which the request ended. Used by the finished notifier to
        /// decide what kind of notification (if any) to send to the user.
        Result result;
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

    mixin RequestCore!(RequestType.SingleNode, RequestCode.Put, 0, Args,
        SharedWorking, Working, Notification);

    /***************************************************************************

        Request handler. Called from RequestOnConn.runHandler().

        Params:
            use_node = delegate to be called to allow the request to send /
                receive data over a specific connection. May be called as many
                times as required by the request
            context_blob = untyped chunk of data containing the serialized
                context of the request which is to be handled
            working_blob = untyped chunk of data containing the serialized
                working data for the request on this connection

    ***************************************************************************/

    public static void handler ( UseNodeDg use_node, void[] context_blob,
        void[] working_blob )
    {
        auto context = Put.getContext(context_blob);
        context.shared_working.result = SharedWorking.Result.Failure;

        // In a real client, you'd have to have some way for a request to decide
        // which node to operate on. In this simple example, we just hard-code
        // the node's address/port.
        IPAddress node;
        node.setAddress("127.0.0.1");
        node.port = 10_000;

        use_node(node,
            ( RequestOnConn.EventDispatcher conn )
            {
                try
                {
                    // Send request info to node
                    conn.send(
                        ( conn.Payload payload )
                        {
                            payload.add(Put.cmd.code);
                            payload.add(Put.cmd.ver);
                            payload.add(context.user_params.args.key);
                            payload.addArray(context.user_params.args.value);
                        }
                    );

                    // Receive status from node
                    auto status = conn.receiveValue!(StatusCode)();
                    if ( Put.handleGlobalStatusCodes(status, context,
                        conn.remote_address) )
                    {
                        // Global codes (not supported / version not supported)
                        context.shared_working.result = SharedWorking.Result.Error;
                    }
                    else
                    {
                        // Put-specific codes
                        with ( RequestStatusCode ) switch ( status )
                        {
                            case Succeeded:
                                context.shared_working.result =
                                    SharedWorking.Result.Put;
                                break;

                            case Error:
                                context.shared_working.result =
                                    SharedWorking.Result.Error;

                                // The node returned an error code. Notify the user.
                                Notification n;
                                n.node_error = RequestNodeInfo(
                                    context.request_id, conn.remote_address);
                                Put.notify(context.user_params, n);
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
                    context.shared_working.result =
                        SharedWorking.Result.Error;

                    Notification n;
                    n.node_disconnected = RequestNodeExceptionInfo(
                        context.request_id, conn.remote_address, e);
                    Put.notify(context.user_params, n);
                }
            });
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
        auto context = Put.getContext(context_blob);

        Notification n;

        with ( SharedWorking.Result ) switch ( context.shared_working.result )
        {
            case Failure:
                n.error = NoInfo();
                break;
            case Put:
                n.succeeded = NoInfo();
                break;
            case Error:
                // Error notification was already handled in handle(), where
                // we have access to the node's address &/ exception.
                return;
            default:
                assert(false);
        }

        Put.notify(context.user_params, n);
    }
}
