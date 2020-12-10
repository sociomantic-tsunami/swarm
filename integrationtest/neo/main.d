/*******************************************************************************

    Simple test for the example client and node. Connects and runs two requests.

    Copyright:
        Copyright (c) 2017 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module integrationtest.neo.main;

import ocean.meta.types.Qualifiers;
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
    import integrationtest.neo.client.Client;
    import integrationtest.neo.node.Node;

    import swarm.neo.client.requests.NotificationFormatter;

    import ocean.core.Enforce;
    import ocean.util.serialize.contiguous.Contiguous;
    import ocean.util.serialize.contiguous.Serializer;
    import ocean.util.serialize.contiguous.MultiVersionDecorator;

    /// Example client.
    private Client client;

    /// Connection notification count wrapper.
    private struct ConnNotifications
    {
        uint connected;
        uint error_while_connecting;
    }

    /// Connection notification counts.
    private ConnNotifications conn_notifications;

    /***************************************************************************

        Task method to be run in a worker fiber.

    ***************************************************************************/

    override public void run ( )
    {
        auto node = new Node(theScheduler.epoll, "127.0.0.1", 10_000);

        this.client = new Client(theScheduler.epoll, "127.0.0.1", 10_000,
            &this.connNotifier);

        this.client.blocking.waitAllNodesConnected();
        enforce(this.conn_notifications == ConnNotifications(1, 0));

        this.testPutGet();
        this.testUnsupported();
        this.testPutGetAll();
        this.testPutGetAllStop();
        this.testPutGetAllSuspend();
        this.testSerialize();
        this.testSerializeVersioned();
        this.testRoundRobinPut();
        this.testDisconnect();
        this.testDoublePut();

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
        with ( info.Active ) switch ( info.active )
        {
            case connected:
                this.conn_notifications.connected++;
                break;

            case error_while_connecting:
                this.conn_notifications.error_while_connecting++;
                break;

            default:
                assert(false);
        }
    }

    /***************************************************************************

        Runs a simple test where a single record is written to the node with Put
        and then fetched with Get.

    ***************************************************************************/

    private void testPutGet ( )
    {
        auto ok = this.client.blocking.put(23, "hello",
            ( Client.Neo.Put.Notification info,
                const(Client.Neo.Put.Args) args ) { });
        enforce(ok, "Put request failed");

        void[] value;
        ok = this.client.blocking.get(23, value,
            ( Client.Neo.Get.Notification info,
                const(Client.Neo.Get.Args) args ) { });
        enforce(ok, "Get request failed");
        enforce(value == cast(void[])"hello");
    }

    /***************************************************************************

        Runs a simple test where an unsupported version of the Get request is
        sent to the node, as a test of the unsupported request handling.

    ***************************************************************************/

    private void testUnsupported ( )
    {
        bool unsupported;
        void notifier ( Client.Neo.Get.Notification info,
            const(Client.Neo.Get.Args) args )
        {
            if ( info.active == info.active.unsupported && info.unsupported.type
                == info.unsupported.type.RequestVersionNotSupported )
            {
                unsupported = true;
            }
        }

        void[] value;
        auto ok = this.client.blocking.get!(23)(23, value, &notifier);
        enforce(!ok, "Unsupported Get request succeeded");
        enforce(value is null);
        enforce(unsupported);
    }

    /***************************************************************************

        Runs a simple test where three records are written to the node with Put
        and then fetched with GetAll.

    ***************************************************************************/

    private void testPutGetAll ( )
    {
        // Add some records. We use very large records so that they can't all be
        // sent and parsed in a single write buffer.
        mstring value;
        value.length = 1024 * 64;
        static immutable records_written = 100;
        for ( hash_t key = 0; key < records_written; key++ )
        {
            auto ok = this.client.blocking.put(key, value,
                ( Client.Neo.Put.Notification info,
                    const(Client.Neo.Put.Args) args ) { });
            enforce(ok, "Put request failed");
        }

        // Check that they're all returned by GetAll.
        size_t received_count;
        bool request_finished;
        this.client.neo.getAll(
            ( Client.Neo.GetAll.Notification info,
                const(Client.Neo.GetAll.Args) args )
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
        // Add some records. We use very large records so that they can't all be
        // sent and parsed in a single write buffer.
        mstring value;
        value.length = 1024 * 64;
        static immutable records_written = 100;
        for ( hash_t key = 0; key < records_written; key++ )
        {
            auto ok = this.client.blocking.put(key, value,
                ( Client.Neo.Put.Notification info,
                    const(Client.Neo.Put.Args) args ) { });
            enforce(ok, "Put request failed");
        }

        // Check that they're all returned by GetAll.
        size_t received_count;
        bool request_finished;
        Client.Neo.RequestId getall_id;
        getall_id = this.client.neo.getAll(
            ( Client.Neo.GetAll.Notification info,
                const(Client.Neo.GetAll.Args) args )
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

        Runs a simple test where records are written to the node with Put
        and then fetched with GetAll. As soon as the first record is received,
        the request is suspended. As soon as the suspension is ACKed by the
        node, the request is resumed.

    ***************************************************************************/

    private void testPutGetAllSuspend ( )
    {
        // Add some records. We use very large records so that they can't all be
        // sent and parsed in a single write buffer.
        mstring value;
        value.length = 1024 * 64;
        static immutable records_written = 100;
        for ( hash_t key = 0; key < records_written; key++ )
        {
            auto ok = this.client.blocking.put(key, value,
                ( Client.Neo.Put.Notification info,
                    const(Client.Neo.Put.Args) args ) { });
            enforce(ok, "Put request failed");
        }

        // Check that they're all returned by GetAll.
        size_t received_count;
        bool request_finished;
        Client.Neo.RequestId getall_id;
        getall_id = this.client.neo.getAll(
            ( Client.Neo.GetAll.Notification info,
                const(Client.Neo.GetAll.Args) args )
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

    /***************************************************************************

        Runs a simple test where a single record is serialized, written to the
        node with Put, fetched with Get, then deserialized.

    ***************************************************************************/

    private void testSerialize ( )
    {
        struct Str
        {
            mstring name;
            uint age;
        }

        Str str;
        str.name = "Bob".dup;
        str.age = 23;

        void[] dst;
        auto ok = this.client.blocking.put(23, Serializer.serialize(str, dst),
            ( Client.Neo.Put.Notification info,
                const(Client.Neo.Put.Args) args ) { });
        enforce(ok, "Put request failed");

        Contiguous!(Str) record;
        bool request_finished;
        bool err;
        this.client.neo.get(23,
            ( Client.Neo.Get.Notification info,
                const(Client.Neo.Get.Args) args )
            {
                with ( info.Active ) switch (info.active )
                {
                    case received:
                        info.received.deserialize(record);
                        break;

                    default:
                        err = true;
                        break;
                }

                request_finished = true;
                this.resume();
            }
        );

        if ( !request_finished )
            this.suspend();

        enforce(!err, "Get request failed");
        enforce!("!is")(record.ptr, null);
        enforce!("==")(record.ptr.name, "Bob");
        enforce!("==")(record.ptr.age, 23);
    }

    /***************************************************************************

        Runs a simple test where a versioned record is serialized, written to
        the node with Put, fetched with Get, then deserialized.

    ***************************************************************************/

    private void testSerializeVersioned ( )
    {
        struct Str
        {
            enum ubyte StructVersion = 23;
            mstring name;
            uint age;
        }

        Str str;
        str.name = "Bob".dup;
        str.age = 23;

        auto version_decorator = new VersionDecorator;
        void[] dst;
        auto ok = this.client.blocking.put(23, version_decorator.store(str, dst),
            ( Client.Neo.Put.Notification info,
                const(Client.Neo.Put.Args) args ) { });
        enforce(ok, "Put request failed");

        Contiguous!(Str) record;
        bool request_finished;
        bool err;
        this.client.neo.get(23,
            ( Client.Neo.Get.Notification info,
                const(Client.Neo.Get.Args) args )
            {
                with ( info.Active ) switch (info.active )
                {
                    case received:
                        info.received.deserialize(record);
                        break;

                    default:
                        err = true;
                        break;
                }

                request_finished = true;
                this.resume();
            }
        );

        if ( !request_finished )
            this.suspend();

        enforce(!err, "Get request failed");
        enforce!("!is")(record.ptr, null);
        enforce!("==")(record.ptr.name, "Bob");
        enforce!("==")(record.ptr.age, 23);
    }

    /***************************************************************************

        Runs a simple test where a second node is added to the client's registry
        and a single record is written to a node with RoundRobinPut.

    ***************************************************************************/

    private void testRoundRobinPut ( )
    {
        auto ok = this.client.blocking.roundRobinPut(23, "hello",
            ( Client.Neo.RoundRobinPut.Notification info,
                Client.Neo.RoundRobinPut.Args args ) { });
        enforce(ok, "RoundRobinPut request failed");
    }

    /***************************************************************************

        Runs a simple test where the connection to the node is shutdown and
        re-established.

    ***************************************************************************/

    private void testDisconnect ( )
    {
        this.conn_notifications = this.conn_notifications.init;
        this.client.neo.reconnect();
        this.client.blocking.waitAllNodesConnected();
        enforce(this.conn_notifications == ConnNotifications(1, 0));
    }

    /***************************************************************************

        Runs a simple test where a second node is added to the client's registry
        and a single record is written to the node with DoublePut.

        Note that this test does not check that the record was written to both
        nodes as the simple test client doesn't have a way of reading from
        specific nodes.

    ***************************************************************************/

    private void testDoublePut ( )
    {
        auto node2 = new Node(theScheduler.epoll, "127.0.0.1", 10_010);

        this.conn_notifications = this.conn_notifications.init;
        this.client.neo.addNode("127.0.0.1", 10_010);

        this.client.blocking.waitAllNodesConnected();
        enforce(this.conn_notifications == ConnNotifications(1, 0));

        auto ok = this.client.blocking.doublePut(23, "hello",
            ( Client.Neo.DoublePut.Notification info,
                const(Client.Neo.DoublePut.Args) args ) { });
        enforce(ok, "DoublePut request failed");
    }
}

/*******************************************************************************

    Initialises the scheduler and runs the test task.

*******************************************************************************/

version ( unittest ) {}
else
void main ( )
{
    initScheduler(SchedulerConfiguration.init);
    theScheduler.schedule(new Test);
    theScheduler.eventLoop();
}
