/*******************************************************************************

    User-facing API for the client's GetAll request.

    Copyright:
        Copyright (c) 2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module test.neo.client.request.GetAll;

import ocean.transition;
import ocean.core.SmartUnion;
import test.neo.client.NotifierTypes;

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
}

/*******************************************************************************

    Notification smart union.

*******************************************************************************/

public alias SmartUnion!(NotificationUnion) Notification;

/*******************************************************************************

    Type of notification delegate.

*******************************************************************************/

public alias void delegate ( Notification, Args ) Notifier;
