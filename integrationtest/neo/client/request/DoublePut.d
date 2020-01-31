/*******************************************************************************

    User-facing API for the client's DoublePut request.

    Copyright:
        Copyright (c) 2017 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module integrationtest.neo.client.request.DoublePut;

import ocean.meta.types.Qualifiers;
import ocean.core.SmartUnion;
import swarm.neo.client.NotifierTypes;

/*******************************************************************************

    Request-specific arguments provided by the user and passed to the notifier.

*******************************************************************************/

public struct Args
{
    hash_t key;
    void[] value;
}

/*******************************************************************************

    Union of possible notifications.

*******************************************************************************/

private union NotificationUnion
{
    /// The request succeeded.
    NoInfo succeeded;

    /// The request succeeded on one node and failed on the other.
    NoInfo partial_success;

    /// The request failed on both nodes.
    NoInfo failed;

    /// The request was tried and failed due to a connection error.
    RequestNodeExceptionInfo node_disconnected;

    /// The request was tried and failed due to an internal node error.
    RequestNodeInfo node_error;

    /// The request was tried and failed because it is unsupported.
    RequestNodeUnsupportedInfo unsupported;

    /// The request failed for an unknown reason, presumably an internal error.
    NoInfo error;
}

/*******************************************************************************

    Notification smart union.

*******************************************************************************/

public alias SmartUnion!(NotificationUnion) Notification;

/*******************************************************************************

    Type of notifcation delegate.

*******************************************************************************/

public alias void delegate ( Notification, const(Args) ) Notifier;
