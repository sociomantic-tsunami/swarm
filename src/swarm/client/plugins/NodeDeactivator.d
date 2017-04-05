/*******************************************************************************

    Version:        2014-01-13: Initial release

    Authors:        Gavin Norman

    Plugin to disable nodes in a flexible node registry based on the occurrence
    of errors or timeouts. Nodes are disabled based on a relative error rate
    calculation, so that if all nodes are on average experiencing similar rates
    of errors, nothing will be disabled.

    Disabled nodes are re-enabled after a configurable pause.

    Copyright:      Copyright (c) 2014-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.plugins.NodeDeactivator;



/*******************************************************************************

    Imports

*******************************************************************************/

import swarm.client.connection.NodeErrorTracker;

import swarm.Const : NodeItem;

import ocean.transition;

/*******************************************************************************

    Node deactivation plugin for swarm client. (To be used with the
    Extensible*Client class templates.)

    Note that this plugin requires a client with the scheduler plugin.

*******************************************************************************/

public class NodeDeactivator
{
    /***************************************************************************

        Configuration options.

        All these options except the counter window size can be changed on the
        fly via public class members. The config class allows them to be set
        initially purely as a convenience for the user.

    ***************************************************************************/

    public static class Config
    {
        bool disable = false;
        ulong counters_window_size_s = NodeErrorTracker.window_size_s_default;
        real deactivate_threshold = default_threshold;
        uint retry_time_ms = default_retry_time_ms;
        float max_disabled_fraction = default_max_disabled_fraction;
    }


    /***************************************************************************

        Per-node error tracker. Helper class which handles error / timeout
        notifications and error rate tracking.

    ***************************************************************************/

    public NodeErrorTracker error_tracker;


    /***************************************************************************

        Flag to switch off node deactivation. If true, no further nodes will be
        deactivated.

    ***************************************************************************/

    public bool disable = false;


    /***************************************************************************

        Per-node error rate threshold value. Nodes are never disabled if they
        have a lower rate of errors than this value.

        Defaults to a rate of one error per second.

    ***************************************************************************/

    public const real default_threshold = 1.0;

    public real threshold = default_threshold;


    /***************************************************************************

        Per-node re-enabling time, in milliseconds, after disabling.

        Defaults to 60 seconds.

    ***************************************************************************/

    public const uint default_retry_time_ms = 60_000;

    public uint retry_time_ms = default_retry_time_ms;


    /***************************************************************************

        Maximum fraction of nodes in the registry which this plugin will
        disable. Once this limit has been reached, the plugin will do nothing
        further until one or more nodes have been re-enabled.

        Defaults to one quarter of the nodes in the registry.

    ***************************************************************************/

    public const float default_max_disabled_fraction = 0.25;

    public float max_disabled_fraction = default_max_disabled_fraction;


    /***************************************************************************

        Constructor.

        Params:
            clock = microseconds clock source

    ***************************************************************************/

    public this ( NodeErrorTracker.Clock clock )
    {
        this.error_tracker = new NodeErrorTracker(clock);
    }


    /***************************************************************************

        Constructor with configuration options.

        Params:
            clock = microseconds clock source
            config = configuration options to set

    ***************************************************************************/

    public this ( NodeErrorTracker.Clock clock, Config config )
    {
        assert(config);

        this.error_tracker = new NodeErrorTracker(clock,
            config.counters_window_size_s);

        this.threshold = config.deactivate_threshold;
        this.retry_time_ms = config.retry_time_ms;
        this.max_disabled_fraction = config.max_disabled_fraction;
        this.disable = config.disable;
    }


    /***************************************************************************

        Code to be mixed into the client.

    ***************************************************************************/

    template Extension ( istring instance )
    {
        /***********************************************************************

            Imports needed by mixin.

        ***********************************************************************/

        import swarm.client.plugins.RequestScheduler;

        import swarm.client.registry.FluidNodeRegistry;

        import ocean.core.Enforce;

        debug ( NodeDeactivator ) import ocean.io.Stdout;


        /***********************************************************************

            This plugin only works in conjunction with the request scheduler
            plugin, so we assert that that also exists in the client.

        ***********************************************************************/

        static assert(HasPlugin!(RequestScheduler),
            "NodeDeactivator plugin requires RequestScheduler plugin");


        /***********************************************************************

            Overrides the default errorReporter() method, which returns null.
            Instead returns an error reporter which tracks the error rate per
            node, and temporarily deactivates nodes whose error rate is
            significantly higher than the average.

            Returns:
                error reporter instance

        ***********************************************************************/

        override protected INodeConnectionPoolErrorReporter errorReporter ( )
        {
            mixin(instance).error_tracker.updated = &this.errorRatesUpdated;
            return mixin(instance).error_tracker;
        }


        /***********************************************************************

            Called by the error tracker when errors have occurred for a node.
            Calculates the average error rate over all nodes in the registry
            and disables a node if it:
                1. exceeds the specified error rate threshold, and
                2. has (approximately) double the error rate of other nodes
                   (the multiplier 1.99 is used for compatibility with 2-node
                   systems, where the deviation from the average error rate can
                   never exceed x2)

            Note that an error rate update (i.e. this method being called) for
            one node triggers a re-assessment of *all* nodes in the registry.

            Params:
                node = address/port of node for which errors occurred

        ***********************************************************************/

        private void errorRatesUpdated ( NodeItem node )
        {
            if ( mixin(instance).disable ) return;

            // Never disable a node if it is the only one in the registry.
            if ( this.nodes.length == 1 )
            {
                debug ( NodeDeactivator ) Stderr.formatln("Only one node");
                return;
            }

            // Do nothing if the maximum allowed fraction of nodes is already
            // disabled.
            auto fluid_registry = cast(FluidNodeRegistry)this.registry;
            enforce(fluid_registry !is null, "NodeDeactivator plugin requires "
                "FluidNodeRegistry");
            auto one_more_node = 1.0 / cast(float)this.nodes.length;
            debug ( NodeDeactivator ) Stderr.formatln("{}% of registry disabled",
                fluid_registry.disabled_fraction);

            if ( fluid_registry.disabled_fraction + one_more_node >
                mixin(instance).max_disabled_fraction )
            {
                debug ( NodeDeactivator ) Stderr.formatln(
                    "No more nodes can be disabled without exceeding max fraction {}",
                    mixin(instance).max_disabled_fraction);
                return;
            }

            // Sum error rate over all nodes and check whether any node has an
            // error rate exceeding the specified threshold.
            real error_rate_per_sec = 0.0;
            bool threshold_exceeded;
            foreach ( n, counter; mixin(instance).error_tracker.node_counters )
            {
                auto per_sec = counter.per_sec;
                error_rate_per_sec += per_sec;

                debug ( NodeDeactivator ) Stderr.formatln("{}:{} -- {}",
                    n.Address, n.Port, per_sec);

                if ( per_sec > mixin(instance).threshold )
                {
                    threshold_exceeded = true;
                }
            }

            // Early bail-out if no counters exceed the specified threshold.
            if ( !threshold_exceeded )
            {
                debug ( NodeDeactivator ) Stderr.formatln("No nodes exceed threshold");
                return;
            }

            // Caulculate warning level at which a node is disabled. This is
            // ~double the mean error rate.
            auto mean_error_rate = error_rate_per_sec / this.nodes.length;
            auto warning_level = mean_error_rate * 1.99;

            // For each node, check whether it exceeds the threshold and the
            // warning level.
            foreach ( node, counter; mixin(instance).error_tracker.node_counters )
            {
                debug ( NodeDeactivator ) Stderr.formatln("err={}, thrsh={}, warn={}",
                    counter.per_sec, mixin(instance).threshold, warning_level);

                if ( counter.per_sec > mixin(instance).threshold
                     && counter.per_sec > warning_level )
                {
                    debug ( NodeDeactivator ) Stderr.formatln("    Disabled");
                    this.deactivate(node, mean_error_rate);
                }
            }
        }


        /***********************************************************************

            Disables the specified node and schedules a re-enable command after
            the configured delay.

            Params:
                node = address/port of node to be deactivated
                error_rate_reset = value to reset the error rate of the node
                    being deactivated to

        ***********************************************************************/

        private void deactivate ( NodeItem node, real error_rate_reset )
        {
            auto node_counter =
                node in mixin(instance).error_tracker.node_counters;
            assert(node_counter);

            node_counter.reset(error_rate_reset);

            // Note: passing null notifiers to these methods, as there's nothing
            // we can do here if they fail, anyway.
            this.assign(this.disableNode(node, null));
            this.schedule(this.enableNode(node, null),
                mixin(instance).retry_time_ms);
        }
    }
}
