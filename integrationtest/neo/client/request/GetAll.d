/*******************************************************************************

    User-facing API for the client's GetAll request.

    Copyright:
        Copyright (c) 2017 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module integrationtest.neo.client.request.GetAll;

import ocean.meta.types.Qualifiers;
import ocean.core.SmartUnion;
import integrationtest.neo.client.NotifierTypes;

/*******************************************************************************

    Request-specific arguments provided by the user and passed to the notifier.

*******************************************************************************/

public struct Args
{
    hash_t key;
}

/*******************************************************************************

    Union of possible notifications.

*******************************************************************************/

private union NotificationUnion
{
    /// All known nodes have either started handling the request or are not
    /// currently connected. The request may now be suspended / resumed /
    /// stopped, via the controller.
    RequestInfo started;

    /// The request is finished. If no error notifications occurred, then all
    /// extant data was transmitted.
    RequestInfo finished;

    /// A value was transmitted.
    RequestKeyDataInfo record;

    /// The request was tried and failed due to a connection error.
    RequestNodeExceptionInfo node_disconnected;

    /// The request was tried and failed due to an internal node error.
    RequestNodeInfo node_error;

    /// The request was tried and failed because it is unsupported.
    RequestNodeUnsupportedInfo unsupported;

    /// The request failed for an unknown reason, presumably an internal or
    /// protocol error.
    RequestInfo error;

    /// All known nodes have either suspended the request (as requested by the
    /// user, via the controller) or are not currently connected.
    RequestInfo suspended;

    /// All known nodes have either resumed the request (as requested by the
    /// user, via the controller) or are not currently connected.
    RequestInfo resumed;

    /// All known nodes have either stopped the request (as requested by the
    /// user, via the controller) or are not currently connected. The request is
    /// now finished.
    RequestInfo stopped;
}

/*******************************************************************************

    Notification smart union.

*******************************************************************************/

public alias SmartUnion!(NotificationUnion) Notification;

/*******************************************************************************

    Type of notification delegate.

*******************************************************************************/

public alias void delegate ( Notification, const(Args) ) Notifier;

/*******************************************************************************

    Request controller, accessible via the client's `control()` method.

    Note that only one control change message can be "in-flight" to the nodes at
    a time. If the controller is used when a control change message is already
    in-flight, the method will return false. The notifier is called when a
    requested control change is carried through.

*******************************************************************************/

public interface IController
{
    /***************************************************************************

        Tells the nodes to stop sending data to this request.

        Returns:
            false if the controller cannot be used because a control change is
            already in progress

    ***************************************************************************/

    bool suspend ( );

    /***************************************************************************

        Tells the nodes to resume sending data to this request.

        Returns:
            false if the controller cannot be used because a control change is
            already in progress

    ***************************************************************************/

    bool resume ( );

    /***************************************************************************

        Tells the nodes to cleanly end the request.

        Returns:
            false if the controller cannot be used because a control change is
            already in progress

    ***************************************************************************/

    bool stop ( );
}
