/*******************************************************************************

    Example client with the following features:
        * Connects to a single node, specified in the constructor.
        * Supports three requests: Put -- to add or update a value in the node;
          Get -- to retrieve a value from the node, if it exists; GetAll -- to
          retrieve all records from the node.
        * A Task-blocking interface for connection and all requests.

    Copyright:
        Copyright (c) 2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module integrationtest.neo.client.Client;

import ocean.transition;

/// ditto
public class Client
{
    import ocean.io.select.EpollSelectDispatcher;
    import swarm.neo.authentication.HmacDef: Key;

    /***************************************************************************

        Neo API.

    ***************************************************************************/

    public class Neo
    {
        import swarm.neo.client.mixins.ClientCore;

        /***********************************************************************

            Imports of requests' public APIs.

        ***********************************************************************/

        public import Get = integrationtest.neo.client.request.Get;
        public import GetAll = integrationtest.neo.client.request.GetAll;
        public import Put = integrationtest.neo.client.request.Put;
        public import DoublePut = integrationtest.neo.client.request.DoublePut;

        /***********************************************************************

            Imports of requests' internal implementations.

        ***********************************************************************/

        struct Internals
        {
            import integrationtest.neo.client.request.internal.GetAll;
            import integrationtest.neo.client.request.internal.Get;
            import integrationtest.neo.client.request.internal.Put;
            import integrationtest.neo.client.request.internal.DoublePut;
        }

        /// Instantiation of ClientCore.
        mixin ClientCore!();

        /// Instantiation of RequestStatsTemplate.
        alias RequestStatsTemplate!("Put", "DoublePut", "Get", "GetAll")
            RequestStats;

        /***********************************************************************

            Assigns a Put request, instructing the node to associate the
            specified value and key.

            Params:
                key = key of record to add to node
                value = value of record to add to node
                notifier = notifier, called when interesting events occur for
                    this request

        ***********************************************************************/

        public void put ( hash_t key, in void[] value, scope Put.Notifier notifier )
        {
            auto params = Const!(Internals.Put.UserSpecifiedParams)(
                Const!(Put.Args)(key, value),
                Const!(Internals.Put.UserSpecifiedParams.SerializedNotifier)(
                    *(cast(Const!(ubyte[notifier.sizeof])*)&notifier)
                )
            );

            this.assign!(Internals.Put)(params);
        }

        /***********************************************************************

            Assigns a DoublePut request, instructing two nodes to associate the
            specified value and key.

            Params:
                key = key of record to add to node
                value = value of record to add to node
                notifier = notifier, called when interesting events occur for
                    this request

        ***********************************************************************/

        public void doublePut ( hash_t key, in void[] value,
            scope DoublePut.Notifier notifier )
        {
            auto params = Const!(Internals.DoublePut.UserSpecifiedParams)(
                Const!(DoublePut.Args)(key, value),
                Const!(Internals.DoublePut.UserSpecifiedParams.SerializedNotifier)(
                    *(cast(Const!(ubyte[notifier.sizeof])*)&notifier)
                )
            );

            this.assign!(Internals.DoublePut)(params);
        }

        /***********************************************************************

            Assigns a Get request, retrieving the value associated in the node
            with the specified key (if one exists).

            Params:
                key = key of record to retrieve from node
                notifier = notifier, called when interesting events occur for
                    this request

        ***********************************************************************/

        public void get ( hash_t key, scope Get.Notifier notifier )
        {
            auto params = Const!(Internals.Get.UserSpecifiedParams)(
                Const!(Get.Args)(key),
                Const!(Internals.Get.UserSpecifiedParams.SerializedNotifier)(
                    *(cast(Const!(ubyte[notifier.sizeof])*)&notifier)
                )
            );

            this.assign!(Internals.Get)(params);
        }

        /***********************************************************************

            Assigns a GetAll request, retrieving all records in the node (if any
            exist).

            The GetAll request is hacked (as an example of sending control
            messages) to stop the iteration after 5 records have been received.

            Params:
                notifier = notifier, called when interesting events occur for
                    this request

            Returns:
                the id of the assigned GetAll request

        ***********************************************************************/

        public RequestId getAll ( scope GetAll.Notifier notifier )
        {
            auto params = Const!(Internals.GetAll.UserSpecifiedParams)(
                Const!(GetAll.Args)(),
                Const!(Internals.GetAll.UserSpecifiedParams.SerializedNotifier)(
                    *(cast(Const!(ubyte[notifier.sizeof])*)&notifier)
                )
            );

            return this.assign!(Internals.GetAll)(params);
        }

        /***********************************************************************

            Gets the type of the wrapper struct of the request associated with
            the specified controller interface.

            Params:
                I = type of controller interface

            Evaluates to:
                the type of the request wrapper struct which contains an
                implementation of the interface I

        ***********************************************************************/

        private template Request ( I )
        {
            static if ( is(I == GetAll.IController ) )
            {
                alias Internals.GetAll Request;
            }
            else
            {
                static assert(false, I.stringof ~ " does not match any request "
                    ~ "controller");
            }
        }

        /***********************************************************************

            Gets access to a controller for the specified request. If the
            request is still active, the controller is passed to the provided
            delegate for use.

            Important usage notes:
                1. The controller is newed on the stack. This means that user
                   code should never store references to it -- it must only be
                   used within the scope of the delegate.
                2. As the id which identifies the request is only known at run-
                   time, it is not possible to statically enforce that the
                   specified ControllerInterface type matches the request. This
                   is asserted at run-time, though (see
                   RequestSet.getRequestController()).

            Params:
                ControllerInterface = type of the controller interface (should
                    be inferred by the compiler)
                id = id of request to get a controller for (the return value of
                    the method which assigned your request)
                dg = delegate which is called with the controller, if the
                    request is still active

            Returns:
                false if the specified request no longer exists; true if the
                controller delegate was called

        ***********************************************************************/

        public bool control ( ControllerInterface ) ( RequestId id,
            scope void delegate ( ControllerInterface ) dg )
        {
            alias Request!(ControllerInterface) R;

            return this.controlImpl!(R)(id, dg);
        }

        /***********************************************************************

            Test instantiating the `control` function template.

        ***********************************************************************/

        unittest
        {
            alias control!(GetAll.IController) getAllControl;
        }
    }

    /***************************************************************************

        Task-blocking neo API.

    ***************************************************************************/

    private class Blocking
    {
        import swarm.neo.client.mixins.TaskBlockingCore;
        import ocean.core.Array : copy;
        import ocean.task.Task;

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

        public bool put ( hash_t key, in void[] value, scope Neo.Put.Notifier notifier )
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

            Assigns a DoublePut request, instructing two nodes to associate the
            specified value and key. The calling Task is blocked until the
            request finishes.

            Params:
                key = key of record to add to nodes
                value = value of record to add to nodes
                notifier = notifier, called when interesting events occur for
                    this request

            Returns:
                true if the DoublePut request succeeded, false on error (on
                either node)

        ***********************************************************************/

        public bool doublePut ( hash_t key, in void[] value,
            scope Neo.DoublePut.Notifier notifier )
        {
            auto task = Task.getThis();
            assert(task !is null);

            bool succeeded, finished;
            void internalNotifier ( Neo.DoublePut.Notification info,
                Neo.DoublePut.Args args )
            {
                notifier(info, args);

                switch ( info.active )
                {
                    case info.active.succeeded:
                        succeeded = true;
                        finished = true;
                        break;
                    case info.active.partial_success:
                        finished = true;
                        break;
                    case info.active.failed:
                        finished = true;
                        break;
                    default:
                        // Do nothing; other notifications are non-final.
                }

                if ( finished && task.suspended )
                    task.resume();
            }

            this.outer.neo.doublePut(key, value, &internalNotifier);
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

        public bool get ( hash_t key, ref void[] value, scope Neo.Get.Notifier notifier )
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

        /***********************************************************************

            GetAll iterator "fruct" (foreach struct).

        ***********************************************************************/

        private struct GetAllFruct
        {
            /// Neo client instance to use to assign the request.
            private Neo neo;

            /// User's notifier delegate.
            private Neo.GetAll.Notifier notifier;


            /*******************************************************************

                foreach iteration over the records returned by a GetAll request.
                The calling Task is blocked until the request finishes.

                Note: in this simple example, the case where the caller breaks
                the foreach loop is not handled. In a real request
                implementation, this should cleanly abort the request.

            *******************************************************************/

            public int opApply (
                scope int delegate ( ref hash_t key, ref Const!(void)[] value ) dg )
            {
                int res;

                auto task = Task.getThis();
                assert(task !is null);

                bool rq_finished;
                void internalNotifier ( Neo.GetAll.Notification info, Neo.GetAll.Args args )
                {
                    (&this).notifier(info, args);

                    with ( info.Active ) switch ( info.active )
                    {
                        case record:
                            res = dg(info.record.key, info.record.value);

                            // This simple iterator implementation does not
                            // support ending the request via breaking the
                            // foreach loop.
                            assert(!res);
                            break;

                        default:
                            // Note that this simple wrapper implementation does
                            // not differentiate between finishing due to an
                            // error vs the request completing.
                            rq_finished = true;
                            break;
                    }

                    if ( rq_finished && task.suspended )
                        task.resume();
                }

                (&this).neo.getAll(&internalNotifier);
                if ( !rq_finished )
                    task.suspend();

                return res;
            }
        }

        /***********************************************************************

            Assigns a GetAll request, retrieving all records in the node (if any
            exist). The calling Task is blocked until the request finishes.

            Params:
                notifier = notifier, called when interesting events occur for
                    this request

            Returns:
                GetAll iterator

        ***********************************************************************/

        public GetAllFruct getAll ( scope Neo.GetAll.Notifier notifier )
        {
            return GetAllFruct(this.outer.neo, notifier);
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
        scope Neo.ConnectionNotifier conn_notifier )
    {
        this.epoll = epoll;
        this.conn_notifier = conn_notifier;

        auto auth_name = "dummy";
        ubyte[] auth_key = Key.init.content;
        this.neo = new Neo(auth_name, auth_key,
            Neo.Settings(this.conn_notifier));
        this.neo.enableSocketNoDelay();
        this.neo.addNode(addr, port);

        this.blocking = new Blocking;
    }

    /***************************************************************************

        Constructor.

        Params:
            epoll = epoll instance to be used by the client
            config = Config instance specifying paths of nodes/auth files
            conn_notifier = connection notifier

    ***************************************************************************/

    public this ( EpollSelectDispatcher epoll, Neo.Config config,
        scope Neo.ConnectionNotifier conn_notifier )
    {
        this.epoll = epoll;
        this.conn_notifier = conn_notifier;

        this.neo = new Neo(config, Neo.Settings(this.conn_notifier));
        this.neo.enableSocketNoDelay();

        this.blocking = new Blocking;
    }
}
