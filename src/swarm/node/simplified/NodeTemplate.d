/*******************************************************************************

    Class template for a swarm node with legacy protocol support.

    Extends swarm.node.simplified.NodeBase with a concrete legacy listener. The
    type of the legacy listener's connection handlers is specified via a
    template argument.

    TODO: this module is a replacement of the deprecated
    swarm.node.model.Node : NodeBase. The difference is that this class melds in
    all neo functionality. When the deprecated module is removed, this module
    may be moved into its place.

    copyright:
        Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.node.simplified.NodeTemplate;

import swarm.node.simplified.LegacyConnectionHandlerBase;
import swarm.node.simplified.NodeBase;

/*******************************************************************************

    Node base template.

    Template params:
        ConnHandler = type of connection handler (the node contains a
            SelectListener instance which owns a pool of instances of this type)

*******************************************************************************/

public class NodeTemplate ( ConnHandler : LegacyConnectionHandlerBase ) : NodeBase
{
    import ocean.transition;
    import ocean.net.server.SelectListener;
    import ocean.sys.socket.AddressIPSocket;
    import ocean.sys.socket.InetAddress;

    /// Legacy protocol select listener alias. A reference to this instance
    /// (i.e. the NodeBase instance) is provided to the select listener to be
    /// passed on to each connection allocated.
    public alias SelectListener!(ConnHandler, NodeBase) LegacyListener;

    /***************************************************************************

        Constructor

        Params:
            options = options for the neo node and connection handlers
            backlog = (see ISelectListener ctor)

    ***************************************************************************/

    public this ( Options options )
    {
        InetAddress!(false) addr;

        // Legacy listener configuration.
        auto socket = new AddressIPSocket!();
        auto listener = new LegacyListener(
            addr(options.addr, options.legacy_port), socket, this,
            options.backlog);

        // Super ctor call.
        super(options, listener, socket);
    }
}

/*******************************************************************************

    Unit tests

*******************************************************************************/

unittest
{
    static class TestConnectionHandler : LegacyConnectionHandlerBase
    {
        import ocean.net.server.connection.IConnectionHandler;

        public this (void delegate(IConnectionHandler) a, NodeBase b)
        {
            super(a, b);
        }
        override protected void handleCommand () {}
    }

    alias NodeTemplate!(TestConnectionHandler) Instance;
}
