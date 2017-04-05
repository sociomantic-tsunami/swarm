/*******************************************************************************

    Version:        2014-01-14: Initial release

    Authors:        Gavin Norman

    Implements the INodeConnectionPoolErrorReporter interface and tracks the
    rate of errors and timeouts encountered by nodes in the client's registry.

    A user-specified delegate is called at most once per second per node, when
    error or timeout events occur.

    Copyright:      Copyright (c) 2014-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.connection.NodeErrorTracker;



/*******************************************************************************

    Imports

*******************************************************************************/

import swarm.client.connection.model.INodeConnectionPoolErrorReporter;

import ocean.time.model.IMicrosecondsClock : IAdvancedMicrosecondsClock;

import core.stdc.time : time_t;

import ocean.math.IEEE : isNaN;



public class NodeErrorTracker : INodeConnectionPoolErrorReporter
{
    /***************************************************************************

        Default window size in seconds (see Weights).

    ***************************************************************************/

    public const ulong window_size_s_default = 60;


    /***************************************************************************

        Weighting constants for exponential moving average calculation. The
        `new_weight` is applied as a multiplier to new event counts and
        `old_weight` to the existing accumulated average. In this way, the
        relevance of previous values decreases exponentially over time.

        The weights are calculated to give an approximate equivalence to the
        specified windowing average, according to the forumla on the following
        site:

        http://www.incrediblecharts.com/indicators/exponential_moving_average.php

    ***************************************************************************/

    private struct Weights
    {
        /***********************************************************************

            Window size (in seconds) used to calculate the weighting factors.
            See above.

            A counter's accumulated value is also reset if it's not been updated
            for longer than the window size.

        ***********************************************************************/

        public ulong window_size_s;


        /***********************************************************************

            Weighting factor applied to values being added to a counter.

        ***********************************************************************/

        public real new_weight;


        /***********************************************************************

            Weighting factor applied to accumulated value, when a new value is
            added to a counter.

        ***********************************************************************/

        public real old_weight;


        /***********************************************************************

            "Constructor". Sets the weighting factors based on the passed window
            size.

            Params:
                window_size_s = window size from which to calculate weighting
                    factors

            Returns:
                new instance with all fields set

        ***********************************************************************/

        public static Weights opCall ( ulong window_size_s )
        {
            Weights instance;
            instance.window_size_s = window_size_s;

            instance.new_weight = 2.0L / (instance.window_size_s + 1);
            instance.old_weight = 1.0L - instance.new_weight;

            return instance;
        }
    }

    private Weights weights;


    /***************************************************************************

        Helper class to track the rate of error/timeout events which have
        occurred on connections to a single node.

        The error rate is tracked using an exponential moving average
        algorithm. See:

        http://en.wikipedia.org/wiki/Moving_average#Exponential_moving_average

    ***************************************************************************/

    private struct NodeCounters
    {
        /***********************************************************************

            Counter for a single event type.

        ***********************************************************************/

        private struct Counter
        {
            /*******************************************************************

                Accumulated count of events for the current second. When the
                second passes, the accumulated count is pushed into the sliding
                average instance (below).

            *******************************************************************/

            private uint count = 0;


            /*******************************************************************

                Timestamp of previous second where an accumulated event count
                was pushed into the sliding average instance.

            *******************************************************************/

            private time_t last_time = 0;


            /*******************************************************************

                Accumulated moving average.

            *******************************************************************/

            private real exp_moving_avg = 0.0;


            /*******************************************************************

                Increments the event counter, and pushes the accumulated count
                into the sliding average instance if the specified timestamp now
                is greater than the previous timestamp at which a push occurred.

                Params:
                    now = timestamp now
                    weights = weighting factors used in average calculation

                Returns:
                    true if the accumulated event count was pushed into the
                    sliding average instance

            *******************************************************************/

            public bool inc ( time_t now, Weights weights )
            {
                assert(now >= this.last_time);
                bool updated;

                if ( now > this.last_time && this.last_time > this.last_time.init )
                {
                    // Push accumulated tick count.
                    this.updateAvg(this.count, weights);
                    this.count = 0;
                    updated = true;

                    // Push empty counts for additional seconds which have
                    // passed. If more than window_size_s have passed, simply
                    // reset the moving average to 0.
                    auto extra_secs = now - this.last_time;
                    if ( extra_secs > weights.window_size_s )
                    {
                        this.exp_moving_avg = 0.0;
                    }
                    else while ( --extra_secs )
                    {
                        this.updateAvg(0, weights);
                    }
                }

                this.count++;
                this.last_time = now;

                return updated;
            }


            /*******************************************************************

                Returns:
                    the average number of events per second, as recorded over
                    the last 60 seconds (the window size defined for the sliding
                    average instance)

            *******************************************************************/

            public real per_sec ( )
            {
                return this.exp_moving_avg;
            }


            /*******************************************************************

                Clears the accumulated event count and sliding average.

                Params:
                    exp_moving_avg = value to reset this.exp_moving_avg to

            *******************************************************************/

            public void reset ( real exp_moving_avg = 0.0 )
            {
                this.count = 0;
                this.exp_moving_avg = exp_moving_avg;
                this.last_time = 0;
            }


            /*******************************************************************

                Updates the exponential moving average with the specified value.

                Params:
                    v = value to add to moving average
                    weights = weighting factors used in average calculation

            *******************************************************************/

            private void updateAvg ( uint v, Weights weights )
            {
                this.exp_moving_avg =
                    (cast(real)v * weights.new_weight) +
                    (this.exp_moving_avg * weights.old_weight);
            }
        }


        /***********************************************************************

            Enum for types of events being tracked per node. The event counters
            are stored in an array (`counters`), to which this enum may be used
            as an index. This allows the counters to be iterated over simply
            with foreach.

        ***********************************************************************/

        public enum CounterType
        {
            Errors,
            IoTimeouts,
            ConnTimeouts
        }


        /***********************************************************************

            Array of counters for this node. Indexed by CounterType.

        ***********************************************************************/

        private Counter[CounterType.max + 1] counters;


        /***********************************************************************

            Gets the average event rate per second -- the sum of all internal
            counters.

            Returns:
                average event rate per second (sum of error, io timeout and
                connection timeout rates)

        ***********************************************************************/

        public real per_sec ( )
        {
            real sum = 0.0;

            foreach ( counter; this.counters )
            {
                auto per_sec = counter.per_sec;
                if ( !isNaN(per_sec) )
                {
                    sum += per_sec;
                }
            }

            return sum;
        }


        /***********************************************************************

            Gets the event rate of the specified counter.

            Params:
                type = type of counter to get value of

            Returns:
                average event rate per second

        ***********************************************************************/

        public real per_sec ( CounterType type )
        {
            return this.counters[type].per_sec;
        }


        /***********************************************************************

            Clears struct to initial state, forgetting all history.

            Params:
                exp_moving_avg = summed error rate value to reset counters to.
                    Each individual counter has its error rate reset to
                    `exp_moving_avg / counters.length`, meaning that per_sec()
                    will return exp_moving_avg

        ***********************************************************************/

        public void reset ( real exp_moving_avg = 0.0 )
        {
            auto per_counter = exp_moving_avg / this.counters.length;
            foreach ( ref counter; this.counters )
            {
                counter.reset(per_counter);
            }
        }
    }


    /***************************************************************************

        Clock source used in the tick() method to get the current time in
        seconds.

    ***************************************************************************/

    public alias IAdvancedMicrosecondsClock Clock;

    private Clock clock;


    /***************************************************************************

        Associative array of NodeCounter instances indexed by the address/port
        of the associated node.

    ***************************************************************************/

    public NodeCounters[NodeItem] node_counters;


    /***************************************************************************

        Delegate to be called when the average of one of the counters is
        updated. This can only be triggered by one of the
        INodeConnectionPoolErrorReporter interface methods being called.

        Note that this delegate is public and non-const as, due to the way the
        construction of client plugins works (the plugin must be constructed
        separately from the IClient instance which owns the node registry, and
        thus a NodeErrorTracker instance), it is not known at the point of
        construction. The delegate may thus be null, although the class is
        pretty much pointless in this case.

    ***************************************************************************/

    public alias void delegate ( NodeItem node ) UpdatedDg;

    public UpdatedDg updated;


    /***************************************************************************

        Constructor.

        Params:
            clock = microseconds clock source to use internally
            window_size_s = window size used to construct Weights instance used
                for all updates

    ***************************************************************************/

    public this ( Clock clock, ulong window_size_s = window_size_s_default )
    {
        this.clock = clock;

        this.weights = Weights(window_size_s);
    }


    /***************************************************************************

        Called when an error occurred.

        Params:
            node = address/port of node responsible for request

    ***************************************************************************/

    public void had_error ( NodeItem node )
    {
        this.tick(node, NodeCounters.CounterType.Errors);
    }


    /***************************************************************************

        Called when an I/O timeout occurred.

        Params:
            node = address/port of node responsible for request

    ***************************************************************************/

    public void had_io_timeout ( NodeItem node )
    {
        this.tick(node, NodeCounters.CounterType.IoTimeouts);
    }


    /***************************************************************************

        Called when a connection timeout occurred.

        Params:
            node = address/port of node responsible for request

    ***************************************************************************/

    public void had_conn_timeout ( NodeItem node )
    {
        this.tick(node, NodeCounters.CounterType.ConnTimeouts);
    }


    /***************************************************************************

        Called by one of the INodeConnectionPoolErrorReporter interface methods
        above. Increments the specified counter type for the specified node and
        calls the update delegate if the average event rate for the node was
        updated.

        Params:
            node = address/port of node for which event occurred
            type = type of counter to increment

    ***************************************************************************/

    private void tick ( NodeItem node, NodeCounters.CounterType type )
    {
        if ( !(node in this.node_counters) )
        {
            this.node_counters[node] = NodeCounters();
        }

        auto updated = this.node_counters[node].counters[type].inc(
            this.clock.now_sec, this.weights);
        if ( updated && this.updated !is null )
        {
            this.updated(node);
        }
    }
}
