/*******************************************************************************

    Client task-blocking core mixin template. Provides basic task-blocking
    features required by a neo client:
        * A method to block the current task until all registered nodes are
          connected.
        * A method to block the current task until at least one registered node
          is connected.
        * A Task-derivative which connects to all registered nodes. (Intended
          for use with Scheduler.await().)
        * A Task-derivative which connects to at least the specified number of
          nodes. (Intended for use with Scheduler.await().)

    Copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.client.mixins.TaskBlockingCore;

/// ditto
template TaskBlockingCore ( )
{
    import ocean.transition;
    import ocean.task.Task;

    import swarm.neo.client.ConnectionSet;
    import swarm.neo.IPAddress;

    /***************************************************************************

        Suspends the current task until all registered nodes are connected.

    ***************************************************************************/

    public void waitAllNodesConnected ( )
    {
        scope stats = this.outer.neo.new Stats;

        bool finished ( )
        {
            return stats.num_connected_nodes == stats.num_registered_nodes;
        }

        this.waitConnect(&finished);
    }

    /***************************************************************************

        Suspends the current task until at least one registered node is
        connected.

    ***************************************************************************/

    public void waitMinOneNodeConnected ( )
    {
        scope stats = this.outer.neo.new Stats;

        bool finished ( )
        {
            return stats.num_connected_nodes > 0;
        }

        this.waitConnect(&finished);
    }

    /***************************************************************************

        Task class which connects to all registered nodes. Intended for use
        with Scheduler.await().

    ***************************************************************************/

    public class AllNodesConnected : Task
    {
        /***********************************************************************

            Task main method. Exits when the client has established a connection
            to all registered nodes.

        ***********************************************************************/

        public override void run ( )
        {
            this.outer.waitAllNodesConnected();
        }
    }

    /***************************************************************************

        Task class which connects to at least the specified number of nodes.
        Intended for use with Scheduler.await() or Scheduler.awaitResult().

    ***************************************************************************/

    public class NodesConnected : Task
    {
        /// When the task exits, holds the number of nodes which are connected.
        public size_t result;

        /// The minimum number of nodes to connect to.
        private size_t minimum_connected;

        /***********************************************************************

            Constructor.

            Params:
                minimum_connected = the minimum number of nodes to connect to

        ***********************************************************************/

        public this ( size_t minimum_connected )
        {
            this.minimum_connected = minimum_connected;
        }

        /***********************************************************************

            Task main method. Exits only when the client has established
            connections to at least this.minimum_connected nodes.

        ***********************************************************************/

        public override void run ( )
        {
            scope stats = this.outer.outer.neo.new Stats;

            bool finished ( )
            {
                return stats.num_connected_nodes >= this.minimum_connected;
            }

            this.outer.waitConnect(&finished);

            this.result = stats.num_connected_nodes;
        }
    }

    /***************************************************************************

        Suspends the current task until the specified finished condition is
        satisifed.

        Params:
            finished = delegate specifying the condition under which the method
                will return. The delegate is called each time the connection
                notifier is called

    ***************************************************************************/

    private void waitConnect ( bool delegate ( ) finished )
    {
        auto task = Task.getThis();
        assert(task !is null, "This method may only be called from inside a Task");

        ConnectionSet.ConnectionNotifier user_conn_notifier;

        void notifier ( ConnectionSet.ConnNotification info )
        {
            user_conn_notifier(info);
            task.resume();
        }

        user_conn_notifier =
            this.outer.neo.connections.setConnectionNotifier(&notifier);
        scope ( exit )
            this.outer.neo.connections.setConnectionNotifier(user_conn_notifier);

        while ( !finished() )
        {
            task.suspend();
        }
    }
}
