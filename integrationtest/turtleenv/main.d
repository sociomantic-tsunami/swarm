/*******************************************************************************

    Test of the abstract turtle node extension.

    Copyright:
        Copyright (c) 2018 sociomantic labs GmbH. All rights reserved.

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module integrationtest.turtleenv.main;

import swarm.neo.AddrPort;
import turtle.env.model.Node;
import ocean.util.test.DirectorySandbox;
import ocean.core.Test;
import ocean.io.device.File;

/// Node used to the turtle test
private class TurtleNode
{
    /// Address and the port of the node
    AddrPort addrport;
    AddrPort neo_address;

    this (AddrPort addrport)
    {
        this.addrport = addrport;
        this.neo_address = AddrPort(this.addrport.address());
        this.neo_address.port = cast(ushort)(this.addrport.port() + 100);
    }
}

/// The turlte TurtleNode class
private class TestNode : Node!(TurtleNode, "turtleNode")
{
    /***********************************************************************

        Creates a fake node at the specified address/port.

        Params:
            node_item = address/port

    ***********************************************************************/

    override protected TurtleNode createNode ( AddrPort addrport )
    {
        return new TurtleNode(addrport);
    }

    /***********************************************************************

        Returns:
            address/port on which node is listening

    ***********************************************************************/

    override public AddrPort node_addrport ( )
    {
        assert(this.node);
        return this.node.addrport;
    }

    /***********************************************************************

        Fake node service stop implementation.

    ***********************************************************************/

    protected override void stopImpl ( )
    {
    }

    /***********************************************************************

        Removes all data from the fake node service.

    ***********************************************************************/

    override public void clear ( )
    {
    }

    /***********************************************************************

        Suppresses log output from the fake node if used version of proto
        supports it.

    ***********************************************************************/

    override public void log_errors ( bool log_errors )
    {
        static if (is(typeof(this.node.log_errors(log_errors))))
            this.node.log_errors(log_errors);
    }
}

version (UnitTest){}
else
void main()
{
    auto sandbox = DirectorySandbox.create();
    scope (success)
        sandbox.remove();

    auto node = new TestNode();
    node.start("127.0.0.1", 10000);
    node.genConfigFiles(".");

    test!("==")(File.get("turtleNode.nodes"), "127.0.0.1:10000\n");
    test!("==")(File.get("turtleNode.neo.nodes"), "127.0.0.1:10100\n");
}
