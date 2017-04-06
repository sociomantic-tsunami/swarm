/*******************************************************************************

    Helper functions to format human-readable information about a request
    notification.

    copyright: Copyright (c) 2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.client.requests.NotificationFormatter;

import ocean.transition;
import ocean.core.SmartUnion;
import ocean.core.Traits : TemplateInstanceArgs, hasMethod;
import Formatter = ocean.text.convert.Formatter;

import swarm.neo.client.NotifierTypes;

/// Alias for a formatting sink delegate.
private alias void delegate ( cstring chunk ) Sink;

/*******************************************************************************

    Formats human-readable information -- suitable for logging -- about the
    provided request notification into the specified buffer.

    Params:
        SU = type of the notification (must be an instantiation of ocean's
            SmartUnion)
        notification = request notification to format info about
        buf = buffer to format into

    Returns:
        formatted buffer

*******************************************************************************/

public cstring formatNotification ( SU ) ( SU notification, ref mstring buf )
{
    buf.length = 0;
    enableStomping(buf);

    formatNotification(notification,
        ( cstring chunk )
        {
            buf ~= chunk;
        }
    );

    return buf;
}

/*******************************************************************************

    Formats human-readable information -- suitable for logging -- about the
    provided request notification, via the specified sink delegate.

    Params:
        SU = type of the notification (must be an instantiation of ocean's
            SmartUnion)
        notification = request notification to format info about
        sink = sink delegate to receive formatted info

*******************************************************************************/

public void formatNotification ( SU ) ( SU notification, Sink sink )
{
    static assert(is(TemplateInstanceArgs!(SmartUnion, SU)));

    Formatter.sformat(
        ( cstring chunk )
        {
            sink(chunk);
            return chunk.length;
        },
        "<{}>", notification.active_name
    );

    .format_sink = sink;
    callWithActive!(.format)(notification);
}

///
unittest
{
    // Imaginary request arguments.
    struct Args
    {
    }

    // Class in your application that assigns and handles swarm client requests.
    static class RequestHandler
    {
        import swarm.neo.client.requests.NotificationFormatter;

        // Reused formatting buffer.
        mstring format_buf;

        /***********************************************************************

            Request notification callback for a request which we imagine has
            been assigned.

            Params:
                info = notification smart-union
                args = original request arguments

        ***********************************************************************/

        void request_notifier ( Notification info, Args args )
        {
            // Format a description of the notification `info`
            auto formatted = formatNotification(info, this.format_buf);

            // ... log or print `formatted`
        }
    }
}

/*******************************************************************************

    Sink delegate to use in `format`, below. Must be set before `format` is
    called.

    Stored as a global variable as a workaround for the fact that the
    SmartUnion helper template, `callWithActive`, cannot access the frame of
    a nested function. (The intuitive location for the function to pass to
    `callWithActive` would be  inside `formatNotification`, above, where the
    function is called and where the user-provided sink delegate is
    available in context.)

*******************************************************************************/

private Sink format_sink;

/*******************************************************************************

    If the provided notification has a `format` method, calls it, passing the
    sink delegate above (`format_sink`, which was provided by the user in
    `formatNotification`, above) to do the actual writing.

    Note that this method is only declared public so that `callWithActive`
    (in SmartUnion) can access it. It is not intended to be called directly
    by the user.

    Params:
        T = type of notification
        notification = notification to format info about, using
            `format_sink`

*******************************************************************************/

public void format ( T ) ( T notification )
in
{
    assert(.format_sink !is null);
}
body
{
    static if ( hasMethod!(T, "toString", void delegate ( Sink )) )
    {
        .format_sink(": ");
        notification.toString(.format_sink);
    }
    else
    {
        .format_sink(": notification without toString method: " ~ T.stringof);
    }
}

version ( UnitTest )
{
    import ocean.core.Test;

    // Dummy notification type with no toString method
    struct Unknown { }

    // Imaginary union of notification types.
    union NotificationUnion
    {
        NoInfo hello;                                       // 1
        NodeInfo connected;                                 // 2
        NodeExceptionInfo connect_error;                    // 3
        RequestInfo request_succeeded;                      // 4
        RequestNodeInfo request_node_error;                 // 5
        RequestNodeUnsupportedInfo request_unsupported;     // 6
        RequestNodeExceptionInfo request_client_error;      // 7
        RequestDataInfo request_data;                       // 8
        Unknown unknown;                                    // 9
    }

    // Imaginary smart-union of notification types.
    alias SmartUnion!(NotificationUnion) Notification;
}

// Test the results of `formatNotification`
unittest
{
    Notification notification;
    mstring buf;

    // NoInfo
    {
        NoInfo n;
        notification.hello = n;
        formatNotification(notification, buf);
        test!("==")(buf, "<hello>: (empty notification)");
    }

    // NodeInfo
    {
        NodeInfo n;
        n.node_addr.setAddress("127.0.0.1");
        n.node_addr.port = 23;
        notification.connected = n;
        formatNotification(notification, buf);
        test!("==")(buf, "<connected>: Node [127, 0, 0, 1]:23");
    }

    // NodeExceptionInfo without an exception (weird, but just to test it works)
    {
        NodeExceptionInfo n;
        notification.connect_error = n;
        formatNotification(notification, buf);
        test!("==")(buf, "<connect_error>: An undefined error (null Exception) occurred in the client while handling the request on node [0, 0, 0, 0]:0");
    }

    // NodeExceptionInfo with an exception
    {
        NodeExceptionInfo n;
        n.e = new Exception("Error", "file.d", 23);
        notification.connect_error = n;
        formatNotification(notification, buf);
        test!("==")(buf, "<connect_error>: Exception 'Error' @ file.d:23 occurred in the client while handling the request on node [0, 0, 0, 0]:0");
    }

    // RequestInfo
    {
        RequestInfo n;
        notification.request_succeeded = n;
        formatNotification(notification, buf);
        test!("==")(buf, "<request_succeeded>: Request #0");
    }

    // RequestNodeInfo
    {
        RequestNodeInfo n;
        n.node_addr.setAddress("127.0.0.1");
        n.node_addr.port = 23;
        notification.request_node_error = n;
        formatNotification(notification, buf);
        test!("==")(buf, "<request_node_error>: Request #0, node [127, 0, 0, 1]:23");
    }

    // RequestNodeUnsupportedInfo with an unsupported request
    {
        RequestNodeUnsupportedInfo n;
        n.type = n.type.RequestNotSupported;
        notification.request_unsupported = n;
        formatNotification(notification, buf);
        test!("==")(buf, "<request_unsupported>: Request #0, node [0, 0, 0, 0]:0 reported that the request is not supported");
    }

    // RequestNodeUnsupportedInfo with an unsupported request version
    {
        RequestNodeUnsupportedInfo n;
        n.type = n.type.RequestVersionNotSupported;
        notification.request_unsupported = n;
        formatNotification(notification, buf);
        test!("==")(buf, "<request_unsupported>: Request #0, node [0, 0, 0, 0]:0 reported that the request version is not supported");
    }

    // RequestNodeExceptionInfo without an exception (weird, but just to test it works)
    {
        RequestNodeExceptionInfo n;
        notification.request_client_error = n;
        formatNotification(notification, buf);
        test!("==")(buf, "<request_client_error>: An undefined error (null Exception) occurred in the client while handling request #0 on node [0, 0, 0, 0]:0");
    }

    // RequestNodeExceptionInfo with an exception
    {
        RequestNodeExceptionInfo n;
        n.e = new Exception("Error", "file.d", 23);
        notification.request_client_error = n;
        formatNotification(notification, buf);
        test!("==")(buf, "<request_client_error>: Exception 'Error' @ file.d:23 occurred in the client while handling request #0 on node [0, 0, 0, 0]:0");
    }

    // RequestDataInfo
    {
        RequestDataInfo n;
        n.value = [1, 2, 3, 4];
        notification.request_data = n;
        formatNotification(notification, buf);
        test!("==")(buf, "<request_data>: Request #0 provided the value [1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 4, 0, 0, 0]");
    }

    // Unknown
    {
        Unknown n;
        notification.unknown = n;
        formatNotification(notification, buf);
        test!("==")(buf, "<unknown>: notification without toString method: Unknown");
    }
}
