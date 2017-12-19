/*******************************************************************************

    Definitions for client request handlers.

    Request handler functions are the functions which define the client-side
    logic to handle each request type.

    There are several different types of request:
        1. Single-node requests: Require a single request-on-conn which is used
           to communicate with a single node at a time. Such requests may query
           multiple nodes, but strictly in sequence.
        2. Round-robin requests: Require a single request-on-conn which is used
           to communicate with a single node. The node is chosen automatically
           by the client, rather than by the request itself.
        3. Multi-node requests: Start with a single request-on-conn, but have
           the ability to acquire more.
        4. All-nodes requests: Require one request-on-conn per connected node.
           We have encountered three sub-types of all-nodes requests, so far:
            a. Short-lived, non-suspendable, getting requests. The nodes sends a
               stream of messages, followed by a "finished" message.
            b. Batch-based, suspendable requests. The node sends a batch of
               records in a single message, then the client sends a response
               telling the node to either send another batch or to end the
               request. The request can be instantaneously suspended by the user
               by halting iteration of the received batch in memory.
            c. Stream-based, suspendable requests. The node sends a stream of
               messages. The request can be suspended by the user, but this
               requires a message to be sent to the nodes, meaning that the
               suspension is not instantaneous.
            d. One-shot commands. The client sends a command to all nodes and
               the nodes respond with a status code.

    Copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.neo.client.RequestHandlers;

/*******************************************************************************

    Imports

*******************************************************************************/

import swarm.neo.AddrPort;
import swarm.neo.client.RequestOnConn;

import ocean.core.SmartUnion;

/*******************************************************************************

    Handler function type for a single-node-at-a-time request. Called once for
    each request.

    Params:
        use_node = delegate to be called from the handler to get access to an
            `EventDispatcher` instance to communicate with the specified node
        context_blob = packed request context struct
        working = serialized per-request-on-conn data

*******************************************************************************/

public alias void function ( UseNodeDg use_node,
    void[] context_blob, void[] working ) SingleNodeHandler;

/*******************************************************************************

    Handler function type for an all-nodes request. Called once per node for
    each request.

    Params:
        ed = `EventDispatcher` instance to communicate with the node
        context_blob = packed request context struct
        working = serialized per-request-on-conn data

*******************************************************************************/

public alias void function ( RequestOnConn.EventDispatcherAllNodes ed,
    void[] context_blob, void[] working ) AllNodesHandler;

/*******************************************************************************

    Handler function type for a node-round-robin request. Called once for each
    request.

    Params:
        rr = iterator to get access to `EventDispatcher` instances to
            communicate with nodes in round-robin sequence
        context_blob = packed request context struct
        working = serialized per-request-on-conn data

*******************************************************************************/

public alias void function ( IRoundRobinConnIterator rr,
    void[] context_blob, void[] working ) RoundRobinHandler;

/*******************************************************************************

    Handler function type for a multi-node request.

    Params:
        use_node = delegate to be called from the handler to get access to an
            `EventDispatcher` instance to communicate with the specified node
        new_request_on_conn = delegate to be called from the handler to cause
            the handler to be called again in a new `RequestOnConn`` instance
        context_blob = packed request context struct

*******************************************************************************/

public alias void function ( UseNodeDg use_node,
    NewRequestOnConnDg new_request_on_conn, void[] context_blob )
    MultiNodeHandler;

/*******************************************************************************

    Delegate type passed to a single-node-at-a-time request handler. Calls `dg`
    with an event dispatcher connected to the node specified by `node_address`.

    Params:
        node_address = the address of the node to communicate with
        dg           = a delegate to call back with an event dispatcher
                       to communicate with the node

    Returns:
        true on success or false if currently not connected to the node,
        `dg` is not called in that case.

*******************************************************************************/

public alias bool delegate ( AddrPort node_address,
    void delegate ( RequestOnConn.EventDispatcher ed ) dg ) UseNodeDg;

/*******************************************************************************

    Delegate type passed to a multi-node request handler. When called, acquires
    a new `RequestOnConn` and calls the handler inside its fiber.

*******************************************************************************/

public alias void delegate ( ) NewRequestOnConnDg;

/*******************************************************************************

    Interface passed to a node-round-robin request. Provides an iterator which
    allows the handler to get an EventDispatcher set up for each connection in
    turn.

*******************************************************************************/

public interface IRoundRobinConnIterator
{
    /***************************************************************************

        `foreach` iteration over all nodes in round-robin fashion. `ed` is
        connected to the node of the current iteration cycle. Each iteration
        as a whole starts with a random node.

    ***************************************************************************/

    public int opApply (
        int delegate ( ref RequestOnConn.EventDispatcher ed ) dg );
}

/*******************************************************************************

    Union of the different types of client request handler to start in a fiber.

*******************************************************************************/

public union Handler
{
    /***************************************************************************

        One all-nodes request callback with one of the nodes.
        This field is active if the outer request is part of an all-nodes
        request.

    ***************************************************************************/

    struct AllNodesWithConnection
    {
        import swarm.neo.client.Connection;

        /***********************************************************************

            The connection that was assigned to this request handler when
            the request was started.

        ***********************************************************************/

        Connection connection;

        /***********************************************************************

            The request handler.

        ***********************************************************************/

        AllNodesHandler   dg;
    }

    AllNodesWithConnection all_nodes;

    /***************************************************************************

        A single-node-at-a-time request callback.
        This field is active only if the outer request is a single-node
        request.

    ***************************************************************************/

    SingleNodeHandler single_node;

    /***************************************************************************

        A multiple-nodes-at-a-time request callback.
        This field is active only if the outer request is a multi-node
        request.

    ***************************************************************************/

    MultiNodeHandler multi_node;

    /***************************************************************************

        A node-round-robin request callback.
        This field is active only if the outer request is a single-node
        request.

    ***************************************************************************/

    RoundRobinHandler round_robin;
}

/*******************************************************************************

    Alias for a smart union of the types of request handlers.

*******************************************************************************/

public alias SmartUnion!(Handler) HandlerUnion;
