/*******************************************************************************

    Example node with the following features:
        * Listens on two ports: one with the neo protocol and one with the
          legacy protocol. The latter protocol is unused in this example.
        * Contains a simplistic key-value storage engine, with string values and
          hash_t keys.
        * Supports three requests: Put -- to add or update a value in the storage
          engine; Get -- to retrieve a value from the storage engine, if
          it exists; GetAll -- to retrieve all records from the storage engine.

    Copyright:
        Copyright (c) 2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module integrationtest.neo.node.Node;

import ocean.transition;
import swarm.node.model.NeoNode;
import swarm.node.connection.ConnectionHandler;
import swarm.Const : ICommandCodes, NodeItem;

/// ditto
public class Node : NodeBase!(ConnHandler)
{
    import ocean.io.select.EpollSelectDispatcher;
    import swarm.neo.authentication.HmacDef: Key;
    import swarm.neo.request.Command;

    import integrationtest.neo.common.RequestCodes;
    import integrationtest.neo.node.Storage;

    import Get = integrationtest.neo.node.request.Get;
    import GetAll = integrationtest.neo.node.request.GetAll;
    import Put = integrationtest.neo.node.request.Put;
    import DoublePut = integrationtest.neo.node.request.DoublePut;

    /***************************************************************************

        Constructor.

        Params:
            epoll = epoll instance with which to register connections
            addr = address to bind to
            neo_port = port to listen on for neo connections

    ***************************************************************************/

    public this ( EpollSelectDispatcher epoll, cstring addr, ushort neo_port )
    in
    {
        assert(neo_port > 2);
    }
    body
    {
        // In this simple example node implementation, we don't need any shared
        // resources except the reference to the storage.
        this.shared_resources = new Storage;

        Options options;
        options.epoll = epoll;

        options.requests.add(Command(RequestCode.Get, 0),
            "Get", &Get.handle_v0);
        options.requests.add(Command(RequestCode.GetAll, 0),
            "GetAll", &GetAll.handle_v0);
        options.requests.add(Command(RequestCode.Put, 0),
            "Put", &Put.handle_v0);
        options.requests.add(Command(RequestCode.DoublePut, 0),
            "DoublePut", &DoublePut.handle_v0);

        options.credentials_map["dummy"] = Key.init;
        options.shared_resources = this.shared_resources;

        const backlog = 1_000;
        auto legacy_port = NodeItem(addr.dup, cast(ushort)(neo_port - 1));
        super(legacy_port, neo_port, new ConnectionSetupParams,
            options, backlog);

        // Register the listening ports with epoll.
        this.register(epoll);
    }

    /***************************************************************************

        Returns:
            string identifying the type of this node

    ***************************************************************************/

    override protected cstring id ( )
    {
        return "example";
    }
}

/*******************************************************************************

    Legacy protocol connection handler. Required by NodeBase but unused in this
    example.

*******************************************************************************/

private class ConnHandler : ConnectionHandlerTemplate!(ICommandCodes)
{
    import ocean.net.server.connection.IConnectionHandler;

    public this ( void delegate(IConnectionHandler) finaliser,
        ConnectionSetupParams params )
    {
        super(finaliser, params);
    }

    override protected void handleCommand () {}

    override protected void handleNone () {}
}
