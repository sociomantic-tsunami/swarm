/*******************************************************************************

    Definitions for client request handlers.

    Request handler functions are the functions which define the client-side
    logic to handle each request type. The "context" of such functions is:
        1. A means of accessing one or more `RequestOnConn`s. (The exact means
           varies by type of request.)
        2. The serialized request context (stored in `Request`). The request
           handler may modify this data, as necessary.
        3. The serialized per-`RequestOnConn` working data (stored in the
           `RequestOnConn`). The request handler may modify this data, as
           necessary.

    Copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.client.RequestHandlers;

/*******************************************************************************

    Imports

*******************************************************************************/

import swarm.neo.IPAddress;
import swarm.neo.client.RequestOnConn;

import ocean.core.SmartUnion;

/*******************************************************************************

    Handler function type for a single-node-at-a-time request. The handler
    should use `use_node(node_address)` to operate via an `EventDispatcher`
    instance to exchange request messages with a node and `io_fiber` for
    customised event handling.

*******************************************************************************/

public alias void function ( UseNodeDg use_node,
    void[] context_blob, void[] working ) SingleNodeHandler;

/*******************************************************************************

    Handler function type for an all-nodes request. The handler should use `ed`
    to exchange request messages with the node and `io_fiber` for customised
    event handling.

*******************************************************************************/

public alias void function ( RequestOnConn.EventDispatcherAllNodes ed,
    void[] context_blob, void[] working ) AllNodesHandler;

/*******************************************************************************

    Handler function type for a node-round-robin request. The handler should use
    `rr` to get access to an event dispatcher to exchange request messages with
    one or more nodes, in series, as required and `io_fiber` for customised
    event handling.

*******************************************************************************/

public alias void function ( IRoundRobinConnIterator rr,
    void[] context_blob, void[] working ) RoundRobinHandler;

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

public alias bool delegate ( IPAddress node_address,
    void delegate ( RequestOnConn.EventDispatcher ed ) dg ) UseNodeDg;

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
