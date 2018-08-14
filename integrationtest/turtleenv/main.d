/*******************************************************************************

    Test of the turtle swarm node extension.

    Copyright:
        Copyright (c) 2018 dunnhumby Germany GmbH. All rights reserved.

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module integrationtest.turtleenv.main;

import ocean.transition;
import ocean.task.Scheduler;
import ocean.task.Task;
import ocean.util.test.DirectorySandbox;
import swarm.Const : ICommandCodes, NodeItem;
import swarm.node.connection.ConnectionHandler;
import turtle.env.model.TestNode;

version (UnitTest){}
else
void main()
{
    auto sandbox = DirectorySandbox.create();
    scope (success)
        sandbox.remove();

    initScheduler(Scheduler.Configuration.init);

    auto node = new MyNode("127.0.0.1", 10000);
    node.start();

    theScheduler.schedule(new Tests(node));
    theScheduler.eventLoop();
}

/*******************************************************************************

    Task that performs tests on the test node passed to the ctor.

*******************************************************************************/

class Tests : Task
{
    import integrationtest.neo.client.Client;
    import ocean.core.Test;
    import ocean.io.device.File;

    /// Node instance to test.
    private MyNode node;

    /// Client instance to use for checking network availability of the node.
    private Client client;

    /***************************************************************************

        Constructor.

        Params:
            node = node to test

    ***************************************************************************/

    public this ( MyNode node )
    {
        this.node = node;
    }

    /***************************************************************************

        Task entry point. Runs a series of tests on the node then shuts down the
        scheduler.

    ***************************************************************************/

    public override void run ( )
    {
        // Test config file generation.
        this.node.genConfigFiles(".");
        test!("==")(File.get("testnode.nodes"), "127.0.0.1:9999\n");
        test!("==")(File.get("testnode.neo.nodes"), "127.0.0.1:10000\n");

        // Initialise client and connect.
        this.client = new Client(theScheduler.epoll, "127.0.0.1", 10000,
            &this.connNotifier);
        client.blocking.waitAllNodesConnected();

        // Try to talk to the node.
        auto ok = this.talkToNode();
        test(ok);

        // Stop the node, then try to talk to it (failure expected).
        this.node.stop();
        ok = this.talkToNode();
        test(!ok);

        // Restart the node, reconnect the client, then try to talk to the node.
        this.node.restart();
        client.blocking.waitAllNodesConnected();
        ok = this.talkToNode();
        test(ok);

        // Finished.
        theScheduler.shutdown();
    }

    /***************************************************************************

        Uses the client to put a record to the node, then read it back.

        Returns:
            true if everything succeeded, false on error

    ***************************************************************************/

    private bool talkToNode ( )
    {
        auto ok = client.blocking.put(1, "hello",
            ( Client.Neo.Put.Notification, Const!(Client.Neo.Put.Args) ) { });
        if ( !ok )
            return false;

        void[] value;
        ok = client.blocking.get(1, value,
            ( Client.Neo.Get.Notification, Const!(Client.Neo.Get.Args) ) { });
        if ( !ok || value != "hello" )
            return false;

        return true;
    }

    /***************************************************************************

        Dummy connection notifier. Required by the client, but unused.

    ***************************************************************************/

    private void connNotifier ( Client.Neo.ConnNotification info )
    {
    }
}

/*******************************************************************************

    Test node implementing the protocol defined in integrationtest.neo.node.

*******************************************************************************/

public class MyNode : TestNode!(ConnHandler)
{
    import swarm.neo.AddrPort;

    import integrationtest.neo.node.Node;
    import integrationtest.neo.node.Storage;
    import integrationtest.neo.node.request.Get;
    import integrationtest.neo.node.request.Put;

    /***************************************************************************

        Constructor.

        Params:
            addr = address to bind to
            neo_port = port to bind to for neo protocol (legacy protocol binds
                to a port one lower)

    ***************************************************************************/

    public this ( cstring addr, ushort neo_port )
    {
        // In this simple example node implementation, we don't need any shared
        // resources except the reference to the storage.
        this.shared_resources = new Storage;

        Options options;
        options.epoll = theScheduler.epoll;
        options.requests.addHandler!(GetImpl_v0)();
        options.credentials_map["dummy"] = Key.init;
        options.shared_resources = this.shared_resources;

        options.requests.addHandler!(GetImpl_v0)();
        options.requests.addHandler!(PutImpl_v0)();

        const backlog = 1_000;
        AddrPort legacy_addr_port;
        legacy_addr_port.setAddress(addr);
        legacy_addr_port.port = cast(ushort)(neo_port - 1);
        super(legacy_addr_port, neo_port, new ConnectionSetupParams,
            options, backlog);
    }

    /***************************************************************************

        Returns:
            identifier string for this node

    ***************************************************************************/

    protected override cstring id ( )
    {
        return "testnode";
    }

    /***************************************************************************

        Scope allocates a request resource acquirer backed by the protected
        `shared_resources`. (Passed as a generic Object to avoid templatising
        this class and others that depend on it.)

        Params:
            handle_request_dg = delegate that receives a resources acquirer and
                initiates handling of a request

    ***************************************************************************/

    override protected void getResourceAcquirer (
        void delegate ( Object resource_acquirer ) handle_request_dg )
    {
        handle_request_dg(this.shared_resources);
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
