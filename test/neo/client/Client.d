/*******************************************************************************

    Example client with the following features:
        * Connects to a single node, specified in the constructor.
        * Supports two simple requests: Put -- to write a value to the node --
          and Get -- to read a value from the node.
        * A Task-blocking interface for connection and both requests.

    Copyright:
        Copyright (c) 2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module test.neo.client.Client;

import ocean.transition;

/// ditto
public class Client
{
    import ocean.io.select.EpollSelectDispatcher;
    import swarm.neo.authentication.HmacDef: Key;

    /***************************************************************************

        Neo API.

    ***************************************************************************/

    private class Neo
    {
        import swarm.neo.client.mixins.ClientCore;
        import swarm.neo.client.IRequestSet : IRequestWorkingData;

        /***********************************************************************

            Imports of requests' public APIs.

        ***********************************************************************/

        public import Get = test.neo.client.request.Get;
        public import Put = test.neo.client.request.Put;

        /***********************************************************************

            Imports of requests' internal implementations.

        ***********************************************************************/

        struct Internals
        {
            import test.neo.client.request.internal.Get;
            import test.neo.client.request.internal.Put;
        }

        /// Instantiation of ClientCore.
        mixin ClientCore!();

        /// Instantiation of RequestStatsTemplate.
        alias RequestStatsTemplate!("Put", "Get") RequestStats;

        /***********************************************************************

            Assigns a Put request, instructing the node to associate the
            specified value and key.

            Params:
                key = key of record to add to node
                value = value of record to add to node
                notifier = notifier, called when interesting events occur for
                    this request

        ***********************************************************************/

        public void put ( hash_t key, cstring value, Put.Notifier notifier )
        {
            Internals.Put.UserSpecifiedParams params;
            params.args.key = key;
            params.args.value = value;
            params.notifier.set(notifier);

            this.assign!(Internals.Put)(params);
        }

        /***********************************************************************

            Assigns a Get request, retrieving the value associated in the node
            with the specified key (if one exists).

            Params:
                key = key of record to retrieve from node
                notifier = notifier, called when interesting events occur for
                    this request

        ***********************************************************************/

        public void get ( hash_t key, Get.Notifier notifier )
        {
            Internals.Get.UserSpecifiedParams params;
            params.args.key = key;
            params.notifier.set(notifier);

            this.assign!(Internals.Get)(params);
        }
    }

    /***************************************************************************

        Task-blocking neo API.

    ***************************************************************************/

    private class Blocking
    {
        import swarm.neo.client.mixins.TaskBlockingCore;
        import ocean.core.Array : copy;

        /// Instantiation of TaskBlockingCore.
        mixin TaskBlockingCore!();

        /***********************************************************************

            Assigns a Put request, instructing the node to associate the
            specified value and key. The calling Task is blocked until the
            request finishes.

            Params:
                key = key of record to add to node
                value = value of record to add to node
                notifier = notifier, called when interesting events occur for
                    this request

            Returns:
                true if the Put request succeeded, false on error

        ***********************************************************************/

        public bool put ( hash_t key, cstring value, Neo.Put.Notifier notifier )
        {
            auto task = Task.getThis();
            assert(task !is null);

            bool succeeded, finished;
            void internalNotifier ( Neo.Put.Notification info, Neo.Put.Args args )
            {
                notifier(info, args);

                if ( info.active == info.active.succeeded )
                    succeeded = true;

                finished = true;
                if ( task.suspended )
                    task.resume();
            }

            this.outer.neo.put(key, value, &internalNotifier);
            if ( !finished )
                task.suspend();

            return succeeded;
        }

        /***********************************************************************

            Assigns a Get request, retrieving the value associated in the node
            with the specified key (if one exists). The calling Task is blocked
            until the request finishes.

            Params:
                key = key of record to retrive from node
                value = output value, receives the value of the record (null, if
                    no value exists for the specified key)
                notifier = notifier, called when interesting events occur for
                    this request

            Returns:
                true if the Get request succeeded, false on error

        ***********************************************************************/

        public bool get ( hash_t key, ref void[] value, Neo.Get.Notifier notifier )
        {
            auto task = Task.getThis();
            assert(task !is null);

            bool succeeded, finished;
            void internalNotifier ( Neo.Get.Notification info, Neo.Get.Args args )
            {
                notifier(info, args);

                with ( info.Active ) switch ( info.active )
                {
                    case received:
                        value.copy(info.received.value);
                        goto case nothing;

                    case nothing:
                        succeeded = true;
                        break;

                    default:
                        succeeded = false;
                        break;
                }

                finished = true;
                if ( task.suspended )
                    task.resume();
            }

            this.outer.neo.get(key, &internalNotifier);
            if ( !finished )
                task.suspend();

            return succeeded;
        }
    }

    /// Epoll instance used by client.
    private EpollSelectDispatcher epoll;

    /// Public neo API.
    public Neo neo;

    /// Public Task-blocking API.
    public Blocking blocking;

    /// Connection notifier passed to the ctor.
    private Neo.ConnectionNotifier conn_notifier;

    /***************************************************************************

        Constructor.

        Params:
            epoll = epoll instance to be used by the client
            addr = address of node to connect to
            port = port on which the node is listening for neo protocol
                connections
            conn_notifier = connection notifier

    ***************************************************************************/

    public this ( EpollSelectDispatcher epoll, cstring addr, ushort port,
        Neo.ConnectionNotifier conn_notifier )
    {
        this.epoll = epoll;
        this.conn_notifier = conn_notifier;

        auto auth_name = "dummy";
        ubyte[] auth_key = Key.init.content;
        this.neo = new Neo(auth_name, auth_key, this.conn_notifier);
        this.neo.addNode(addr, port);

        this.blocking = new Blocking;
    }
}
