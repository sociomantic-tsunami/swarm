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
        this.testPutGetAllStop();
        this.testPutGetAllSuspend();

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
    }

    /***************************************************************************

        Runs a simple test where a single record is written to the node with Put
        and then fetched with Get.

    ***************************************************************************/

    private void testPutGet ( )
    {
        mstring msg_buf;

        auto ok = this.client.blocking.put(23, "hello",
            ( Client.Neo.Put.Notification info, Client.Neo.Put.Args args ) { });
        enforce(ok, "Put request failed");

        void[] value;
        ok = this.client.blocking.get(23, value,
            ( Client.Neo.Get.Notification info, Client.Neo.Get.Args args ) { });
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

        // Add some records. We use very large records so that they can't all be
        // sent and parsed in a single write buffer.
        mstring value;
        value.length = 1024 * 64;
        const records_written = 100;
        for ( hash_t key = 0; key < records_written; key++ )
        {
            auto ok = this.client.blocking.put(key, value,
                ( Client.Neo.Put.Notification info, Client.Neo.Put.Args args ) { });
            enforce(ok, "Put request failed");
        }

        // Check that they're all returned by GetAll.
        size_t received_count;
        bool request_finished;
        this.client.neo.getAll(
            ( Client.Neo.GetAll.Notification info, Client.Neo.GetAll.Args args )
            {
                with ( info.Active ) switch ( info.active )
                {
                    case record:
                        received_count++;
                        break;

                    case started:
                    case suspended:
                    case resumed:
                        break;

                    default:
                        request_finished = true;
                        if ( this.suspended )
                            this.resume();
                }
            }
        );

        if ( !request_finished )
            this.suspend();

        enforce!("==")(received_count, records_written);
    }

    /***************************************************************************

        Runs a simple test where three records are written to the node with Put
        and then fetched with GetAll.

        The GetAll request is hacked (as an example of sending control messages)
        to stop the iteration after 5 records have been received.

    ***************************************************************************/

    private void testPutGetAllStop ( )
    {
        mstring msg_buf;

        // Add some records. We use very large records so that they can't all be
        // sent and parsed in a single write buffer.
        mstring value;
        value.length = 1024 * 64;
        const records_written = 100;
        for ( hash_t key = 0; key < records_written; key++ )
        {
            auto ok = this.client.blocking.put(key, value,
                ( Client.Neo.Put.Notification info, Client.Neo.Put.Args args ) { });
            enforce(ok, "Put request failed");
        }

        // Check that they're all returned by GetAll.
        size_t received_count;
        bool request_finished;
        Client.Neo.RequestId getall_id;
        getall_id = this.client.neo.getAll(
            ( Client.Neo.GetAll.Notification info, Client.Neo.GetAll.Args args )
            {
                with ( info.Active ) switch ( info.active )
                {
                    case record:
                        received_count++;
                        // As soon as we receive something, stop the request.
                        if ( received_count == 1 )
                            this.client.neo.control(getall_id,
                            ( Client.Neo.GetAll.IController controller )
                            {
                                controller.stop();
                            }
                        );

                        break;

                    case started:
                    case suspended:
                    case resumed:
                        break;

                    default:
                        request_finished = true;
                        if ( this.suspended )
                            this.resume();
                }
            }
        );

        if ( !request_finished )
            this.suspend();

        enforce!(">=")(received_count, 5);
    }

    /***************************************************************************

        Runs a simple test where three records are written to the node with Put
        and then fetched with GetAll. As soon as the first record is received,
        the request is suspended. As soon as the suspension is ACKed by the
        node, the request is resumed.

    ***************************************************************************/

    private void testPutGetAllSuspend ( )
    {
        mstring msg_buf;

        // Add some records. We use very large records so that they can't all be
        // sent and parsed in a single write buffer.
        mstring value;
        value.length = 1024 * 64;
        const records_written = 100;
        for ( hash_t key = 0; key < records_written; key++ )
        {
            auto ok = this.client.blocking.put(key, value,
                ( Client.Neo.Put.Notification info, Client.Neo.Put.Args args ) { });
            enforce(ok, "Put request failed");
        }

        // Check that they're all returned by GetAll.
        size_t received_count;
        bool request_finished;
        Client.Neo.RequestId getall_id;
        getall_id = this.client.neo.getAll(
            ( Client.Neo.GetAll.Notification info, Client.Neo.GetAll.Args args )
            {
                with ( info.Active ) switch ( info.active )
                {
                    case record:
                        received_count++;
                        // As soon as we receive something, suspend the request.
                        if ( received_count == 1 )
                            this.client.neo.control(getall_id,
                            ( Client.Neo.GetAll.IController controller )
                            {
                                controller.suspend();
                            }
                        );

                        break;

                    case started:
                    case resumed:
                        break;

                    case suspended:
                        // As soon as the request is suspended, resume it again.
                        this.client.neo.control(getall_id,
                            ( Client.Neo.GetAll.IController controller )
                            {
                                controller.resume();
                            }
                        );
                        break;

                    default:
                        request_finished = true;
                        if ( this.suspended )
                            this.resume();
                }
            }
        );

        if ( !request_finished )
            this.suspend();

        enforce!("==")(received_count, records_written);
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
