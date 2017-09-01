/*******************************************************************************

    Example node with the following features:
        * Listens on one port with the neo protocol.
        * Contains a simplistic key-value storage engine, with string values and
          hash_t keys.
        * Supports three requests: Put -- to add or update a value in the
          storage engine; Get -- to retrieve a value from the storage engine, if
          it exists; GetAll -- to retrieve all records from the storage engine.

    Copyright:
        Copyright (c) 2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module test.neo.node.Node;

import ocean.transition;
import swarm.node.simplified.NodeBase;
import swarm.node.simplified.LegacyConnectionHandlerTemplate;
import swarm.Const : ICommandCodes, NodeItem;

/// ditto
public class Node : NodeBase
{
    import ocean.io.select.EpollSelectDispatcher;
    import swarm.neo.authentication.HmacDef: Key;

    import test.neo.common.RequestCodes;
    import test.neo.node.Storage;

    import Get = test.neo.node.request.Get;
    import GetAll = test.neo.node.request.GetAll;
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
        options.addr = addr;
        options.legacy_port = cast(ushort)(neo_port - 1);
        options.backlog = 1_000;

        options.support_neo = true;
        options.neo_port = neo_port;
        options.cmd_handlers[RequestCode.Get] = &Get.handle;
        options.cmd_handlers[RequestCode.GetAll] = &GetAll.handle;
        options.cmd_handlers[RequestCode.Put] = &Put.handle;
        options.credentials_map["dummy"] = Key.init;
        options.shared_resources = this.storage;

        super(options, null, null);

        // Register the listening ports with epoll.
        this.register();
    }
}
