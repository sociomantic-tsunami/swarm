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
        // Dummy (not required by this request)
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

            // Handle messages from node
            bool finished;
            do
            {
                conn.receive(
                    ( in void[] const_message )
                    {
                        Const!(void)[] message = const_message;
                        auto msg_type = *conn.message_parser.
                            getValue!(MessageType)(message);

                        with ( MessageType ) switch ( msg_type )
                        {
                            case Record:
                                auto key = *conn.message_parser.
                                    getValue!(hash_t)(message);
                                auto value = conn.message_parser.
                                    getArray!(char)(message);

                                Notification n;
                                n.record = RequestKeyDataInfo(context.request_id,
                                    key, value);
                                GetAll.notify(context.user_params, n);
                                break;

                            case End:
                                finished = true;
                                break;

                            default:
                                Notification n;
                                n.error = RequestInfo(context.request_id);
                                GetAll.notify(context.user_params, n);
                                goto case End;
                        }
                    }
                );
            }
            while ( !finished );
        }
        catch ( IOError e )
        {
            // A connection error occurred. Notify the user.
            Notification n;
            n.node_disconnected = RequestNodeExceptionInfo(
                context.request_id, conn.remote_address, e);
            GetAll.notify(context.user_params, n);
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

        Notification n;
        n.finished = RequestInfo(context.request_id);
        GetAll.notify(context.user_params, n);
    }
}
