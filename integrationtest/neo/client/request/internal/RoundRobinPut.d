/*******************************************************************************

    Internal implementation of the client's RoundRobinPut request.

    Copyright:
        Copyright (c) 2018 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module integrationtest.neo.client.request.internal.RoundRobinPut;

import ocean.transition;

/*******************************************************************************

    RoundRobinPut request implementation.

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

public struct RoundRobinPut
{
    import integrationtest.neo.common.RoundRobinPut;
    import integrationtest.neo.client.request.RoundRobinPut;
    import integrationtest.neo.common.RequestCodes;
    import swarm.neo.client.mixins.RequestCore;
    import swarm.neo.client.RequestHandlers : IRoundRobinConnIterator;

    import ocean.io.select.protocol.generic.ErrnoIOException: IOError;

    /***************************************************************************

        Data which the request needs while it is progress. An instance of this
        struct is stored per connection on which the request runs and is passed
        to the request handler.

    ***************************************************************************/

    private static struct SharedWorking
    {
        /// Did the request succeed on a node?
        bool succeeded;
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

    mixin RequestCore!(RequestType.RoundRobin, RequestCode.RoundRobinPut, 0, Args,
        SharedWorking, Working, Notification);

    /***************************************************************************

        Request handler. Called from RequestOnConn.runHandler().

        Params:
            conns = round-robin getter for per-connection event dispatchers
            context_blob = untyped chunk of data containing the serialized
                context of the request which is to be handled
            working_blob = untyped chunk of data containing the serialized
                working data for the request on this connection

    ***************************************************************************/

    public static void handler ( IRoundRobinConnIterator conns,
        void[] context_blob, void[] working_blob )
    {
        auto context = RoundRobinPut.getContext(context_blob);
        context.shared_working.succeeded = false;

        round_robin: foreach (conn; conns)
        {
            try
            {
                // Send request info to node
                conn.send(
                    ( conn.Payload payload )
                    {
                        payload.add(RoundRobinPut.cmd.code);
                        payload.add(RoundRobinPut.cmd.ver);
                        payload.add(context.user_params.args.key);
                        payload.addArray(context.user_params.args.value);
                    }
                );
                conn.flush();

                // Receive supported status from node
                auto supported = conn.receiveValue!(SupportedStatus)();
                if ( RoundRobinPut.handleSupportedCodes(supported, context,
                    conn.remote_address) )
                {
                    // Receive result message from node
                    auto result = conn.receiveValue!(MessageType)();
                    with ( MessageType ) switch ( result )
                    {
                        case Succeeded:
                            context.shared_working.succeeded = true;
                            break round_robin;

                        case Error:
                            // The node returned an error code. Notify the user.
                            Notification n;
                            n.node_error = RequestNodeInfo(
                                context.request_id, conn.remote_address);
                            RoundRobinPut.notify(context.user_params, n);
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
                Notification n;
                n.node_disconnected = RequestNodeExceptionInfo(
                    context.request_id, conn.remote_address, e);
                RoundRobinPut.notify(context.user_params, n);
            }
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
        auto context = RoundRobinPut.getContext(context_blob);
        Notification n;

        if ( context.shared_working.succeeded )
            n.succeeded = NoInfo();
        else
            n.failure = NoInfo();

        RoundRobinPut.notify(context.user_params, n);
    }
}
