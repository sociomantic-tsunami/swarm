/*******************************************************************************

    Simple test for the example client and node. Connects and runs two requests.

    Copyright:
        Copyright (c) 2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module test.neo.main;

import ocean.transition;
import ocean.task.Scheduler;
import ocean.task.Task;

/*******************************************************************************

    Task which does the following:
        1. Constructs a node and registers its listening sockets with epoll.
        2. Constructs a client and sets it to connect to the node.
        3. Blocks until the connection has succeeded.
        4. Assigns a Put request to write a record to the node. Blocks until the
           request has finished.
        5. Assigns a Get request to retrieve the record from the node. Blocks
           until the request has finished.
        6. Shuts down the scheduler to exit.

*******************************************************************************/

class Test : Task
{
    import test.neo.client.Client;
    import test.neo.node.Node;

    import swarm.neo.client.requests.NotificationFormatter;

    import ocean.core.Enforce;
    import ocean.io.Stdout;

    /// Example node.
    Node node;

    /// Example client.
    Client client;

    /***************************************************************************

        Task method to be run in a worker fiber.

    ***************************************************************************/

    override public void run ( )
    {
        this.node = new Node(theScheduler.epoll, "127.0.0.1", 10_000);
        this.client = new Client(theScheduler.epoll, "127.0.0.1", 10_000,
            &this.connNotifier);

        this.client.blocking.waitAllNodesConnected();

        this.testPutGet();
        this.testPutGetAll();

        theScheduler.shutdown();
    }

    /***************************************************************************

        Delegate called by the client when an event relating to a connection
        (e.g. connection established or connection error) occurs.

        Params:
            info = smart-union whose active member describes the notification

    ***************************************************************************/

    private void connNotifier ( Client.Neo.ConnNotification info )
    {
        mstring buf;
        formatNotification(info, buf);
        Stdout.formatln("Conn: {}", buf);
    }

    /***************************************************************************

        Runs a simple test where a single record is written to the node with Put
        and then fetched with Get.

    ***************************************************************************/

    private void testPutGet ( )
    {
        mstring msg_buf;

        auto ok = this.client.blocking.put(23, "hello",
            ( Client.Neo.Put.Notification info, Client.Neo.Put.Args args )
            {
                formatNotification(info, msg_buf);
                Stdout.formatln("Put: {}", msg_buf);
            }
        );
        enforce(ok, "Put request failed");

        void[] value;
        ok = this.client.blocking.get(23, value,
            ( Client.Neo.Get.Notification info, Client.Neo.Get.Args args )
            {
                formatNotification(info, msg_buf);
                Stdout.formatln("Get: {}", msg_buf);
            }
        );
        enforce(ok, "Get request failed");
        enforce(value == cast(void[])"hello");
    }

    /***************************************************************************

        Runs a simple test where three records are written to the node with Put
        and then fetched with GetAll.

    ***************************************************************************/

    private void testPutGetAll ( )
    {
        mstring msg_buf;

        // Add some records.
        cstring[hash_t] records =
            [0x1 : "you"[], 0x2 : "say", 23 : "hello"];
        foreach ( key, value; records )
        {
            auto ok = this.client.blocking.put(key, value,
                ( Client.Neo.Put.Notification info, Client.Neo.Put.Args args ) { });
            enforce(ok, "Put request failed");
        }

        // Check that they're all returned by GetAll.
        auto records_iterator = this.client.blocking.getAll(
            ( Client.Neo.GetAll.Notification info, Client.Neo.GetAll.Args args ) { });

        size_t received_count;
        foreach ( key, value; records_iterator )
        {
            enforce!("in")(key, records);
            received_count++;
        }
        enforce!("==")(received_count, records.length);
    }
}

/*******************************************************************************

    Initialises the scheduler and runs the test task.

*******************************************************************************/

void main ( )
{
    initScheduler(SchedulerConfiguration.init);
    theScheduler.schedule(new Test);
    theScheduler.eventLoop();
}
