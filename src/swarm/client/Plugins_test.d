/*******************************************************************************

    Test that legacy plugins compile with client core

    copyright:
        Copyright (c) 2018 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.client.Plugins_test;

import swarm.client.model.IClient;
import swarm.util.ExtensibleClass;
import swarm.client.plugins.NodeDeactivator;
import swarm.client.plugins.RequestScheduler;
import swarm.client.plugins.RequestQueueDiskOverflow;
import swarm.client.plugins.ScopeRequests;

// Check that the client and plugins compile.
class Client : IClient
{
    import swarm.client.request.notifier.IRequestNotification;

    mixin ExtensibleClass!(ScopeRequestsPlugin, RequestScheduler,
        RequestQueueDiskOverflow, NodeDeactivator);

    // Required by ScopeRequests (don't ask me why)
    alias IRequestNotification RequestNotification;

    this ( )
    {
        super(null, null);
    }

    override protected void scopeRequestParams (
        void delegate ( IRequestParams params ) dg ) { }

    // Required by NodeDeactivator
    void assign ( T ) ( T request ) { }
}
