/*******************************************************************************

    Client task-blocking core mixin template. Provides basic task-blocking
    features required by a neo client:
        * A method to block the current task until all registered nodes are
          connected.
        * A method to block the current task until at least one registered node
          is connected.

    Copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

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

        void notifier ( IPAddress node_address, Exception e )
        {
            user_conn_notifier(node_address, e);
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
