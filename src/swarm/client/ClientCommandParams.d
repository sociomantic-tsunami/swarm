/*******************************************************************************

    Structure holding parameters for a client command (a command assigned to a
    client which only affects the client itself and has no communication with or
    effect on a node).

    copyright:      Copyright (c) 2012-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.ClientCommandParams;



/*******************************************************************************

    Imports

*******************************************************************************/

import swarm.Const : NodeItem;



/*******************************************************************************

    Client command struct

*******************************************************************************/

public struct ClientCommandParams
{
    /***************************************************************************

        Command code.

    ***************************************************************************/

    public enum Command
    {
        None,
        SuspendNode,             // suspends processing of further requests to a
                                 // node. Requests can still be assigned to this
                                 // node, but will simply be queued.
        ResumeNode,              // resumes processing of requests to a node
        Disconnect,              // disconnects all connections to all nodes
        DisconnectNodeIdleConns, // disconnects all idle connections to a node
        Flush,                   // flushes all data pending in the write
                                 // buffers of stream commands
        DisableNode,             // disables a node in the registry. No further
                                 // requests can be assigned to this node.
        EnableNode               // re-enables a disabled node in the registry
    }

    public Command command;


    /***************************************************************************

        Node connection pool which command operates on.

    ***************************************************************************/

    public NodeItem nodeitem;
}

