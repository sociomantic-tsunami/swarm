/*******************************************************************************

    User-facing API for the client's RoundRobinPut request.

    Puts the specified record to one node, with nodes queried in a round-robin
    fashion.

    Copyright:
        Copyright (c) 2018 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module integrationtest.neo.client.request.RoundRobinPut;

import ocean.transition;
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

    /// The request was tried on a node and failed due to a connection error;
    /// it will be retried on any remaining nodes.
    RequestNodeExceptionInfo node_disconnected;

    /// The request was tried on a node and failed due to an internal node
    /// error; it will be retried on any remaining nodes.
    RequestNodeInfo node_error;

    /// The request was tried and failed because it is unsupported.

    /// The request was tried on a node and failed because it is unsupported; it
    /// will be retried on any remaining nodes.
    RequestNodeUnsupportedInfo unsupported;

    /// The request tried all nodes and failed.
    NoInfo failure;
}

/*******************************************************************************

    Notification smart union.

*******************************************************************************/

public alias SmartUnion!(NotificationUnion) Notification;

/*******************************************************************************

    Type of notifcation delegate.

*******************************************************************************/

public alias void delegate ( Notification, Args ) Notifier;
