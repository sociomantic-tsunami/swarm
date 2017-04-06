/*******************************************************************************

    Example node with the following features:
        * Listens on two ports: one with the neo protocol and one with the
          legacy protocol. The latter protocol is unused in this example.
        * Contains a simplistic key-value storage engine, with string values and
          hash_t keys.
        * Supports tow requests: Put -- to add or update a value in the storage
          engine -- and Get -- to retrieve a value from the storage engine, if
          it exists.

    Copyright:
        Copyright (c) 2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module test.neo.node.Node;

import ocean.transition;
import swarm.node.model.NeoNode;
import swarm.node.connection.ConnectionHandler;
import swarm.Const : ICommandCodes, NodeItem;

/// ditto
public class Node : NodeBase!(ConnHandler)
{
    import ocean.io.select.EpollSelectDispatcher;
    import swarm.neo.authentication.HmacDef: Key;

    import test.neo.common.RequestCodes;
    import test.neo.node.Storage;

    import Get = test.neo.node.request.Get;
    import Put = test.neo.node.request.Put;

    /// Storage engine.
    private Storage storage;

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
        this.storage = new Storage;

        Options options;
        options.epoll = epoll;
        options.cmd_handlers[RequestCode.Get] = &Get.handle;
        options.cmd_handlers[RequestCode.Put] = &Put.handle;
        options.credentials_map["dummy"] = Key.init;
        options.shared_resources = this.storage;

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
