/*******************************************************************************

    Internal implementation of the client's Get request.

    Copyright:
        Copyright (c) 2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module integrationtest.neo.client.request.internal.Get;

import ocean.transition;

/// Default (v0) Get implementation.
public alias VersionedGet!(0) Get;

/*******************************************************************************

    Get request implementation.

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

    Params:
        Version = request version (used for testing the version handling
            support of the client and node by sending an unsupported request)

*******************************************************************************/

public struct VersionedGet ( ubyte Version )
{
    import integrationtest.neo.common.Get;
    import integrationtest.neo.client.request.Get;
    import integrationtest.neo.common.RequestCodes;
    import swarm.neo.AddrPort;
    import swarm.neo.request.Command;
    import swarm.neo.client.RequestOnConn;
    import swarm.neo.client.NotifierTypes;
    import swarm.neo.client.mixins.RequestCore;
    import swarm.neo.client.RequestHandlers : UseNodeDg;

    import ocean.io.select.protocol.generic.ErrnoIOException: IOError;

    mixin TypeofThis;

    /***************************************************************************

        Data which the request needs while it is progress. An instance of this
        struct is stored per connection on which the request runs and is passed
        to the request handler.

    ***************************************************************************/

    public static struct SharedWorking
    {
        /// Enum indicating the ways in which the request may end.
        public enum Result
        {
            Failure,    // Default value; unknown error (presumably in client)
            Error,      // Node or I/O error
            Empty,      // Record not found
            Received    // Received record
        }

        /// The way in which the request ended. Used by the finished notifier to
        /// decide what kind of notification (if any) to send to the user.
        Result result;
    }

    /***************************************************************************

        Request core. Mixes in the types `NotificationInfo`, `Notifier`,
        `Params`, `Context` plus the static constants `request_type` and
        `request_code`.

    ***************************************************************************/

    mixin RequestCore!(RequestType.SingleNode, RequestCode.Get, Version, Args,
        SharedWorking, Notification);

    /***************************************************************************

        Request handler. Called from RequestOnConn.runHandler().

        Params:
            use_node = delegate to be called to allow the request to send /
                receive data over a specific connection. May be called as many
                times as required by the request
            context_blob = untyped chunk of data containing the serialized
                context of the request which is to be handled

    ***************************************************************************/

    public static void handler ( scope UseNodeDg use_node, void[] context_blob )
    {
        auto context = This.getContext(context_blob);
        context.shared_working.result = SharedWorking.Result.Failure;

        // In a real client, you'd have to have some way for a request to decide
        // which node to operate on. In this simple example, we just hard-code
        // the node's address/port.
        AddrPort node;
        node.setAddress("127.0.0.1");
        node.port = 10_000;
        scope dg = ( RequestOnConn.EventDispatcher conn )
        {
            try
            {
                // Send request info to node
                scope send_cb = ( conn.Payload payload )
                {
                    payload.add(This.cmd.code);
                    payload.add(This.cmd.ver);
                    payload.add(context.user_params.args.key);
                };
                conn.send(send_cb);

                // Receive supported status from node
                auto supported = conn.receiveValue!(SupportedStatus)();
                if ( !This.handleSupportedCodes(supported, context,
                    conn.remote_address) )
                {
                    // Global codes (not supported / version not supported)
                    context.shared_working.result = SharedWorking.Result.Error;
                }
                else
                {
                    // Receive result code from node
                    auto result = conn.receiveValue!(StatusCode)();

                    with ( RequestStatusCode ) switch ( result )
                    {
                        case Value:
                            context.shared_working.result =
                                SharedWorking.Result.Received;

                            scope recv_cb = ( in void[] const_payload )
                            {
                                Const!(void)[] payload = const_payload;
                                auto value =
                                    conn.message_parser.getArray!(void)(payload);

                                Notification n;
                                n.received = RequestDataInfo(
                                    context.request_id, value);
                                This.notify(context.user_params, n);
                            };

                            // Receive record value from node.
                            conn.receive(recv_cb);
                            break;

                        case Empty:
                            context.shared_working.result =
                                SharedWorking.Result.Empty;
                            break;

                        case Error:
                            context.shared_working.result =
                                SharedWorking.Result.Error;

                            // The node returned an error code. Notify the user.
                            Notification n;
                            n.node_error = RequestNodeInfo(
                                context.request_id, conn.remote_address);
                            This.notify(context.user_params, n);
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
                This.notify(context.user_params, n);
            }
        };

        use_node(node, dg);
    }

    /***************************************************************************

        Request finished notifier. Called from Request.handlerFinished().

        Params:
            context_blob = untyped chunk of data containing the serialized
                context of the request which is finishing

    ***************************************************************************/

    public static void all_finished_notifier ( void[] context_blob )
    {
        auto context = This.getContext(context_blob);

        Notification n;

        with ( SharedWorking.Result ) switch ( context.shared_working.result )
        {
            case Empty:
                n.nothing = NoInfo();
                break;
            case Failure:
                n.error = NoInfo();
                break;
            case Received:
                // Received notification was already handled in handle(), where
                // the value received from the node is available.
                return;
            case Error:
                // Error notification was already handled in handle(), where
                // we have access to the node's address &/ exception.
                return;
            default:
                assert(false);
        }

        This.notify(context.user_params, n);
    }
}
