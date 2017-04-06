/*******************************************************************************

    Swarm client error/timeout log.

    Version:        2013-02-19: Initial release

    Authors:        Gavin Norman

    When an instance of ClientStats is created, it registers a timer with the
    provided epoll instance. When the timer fires, a set of clients (to be set
    by the user of the class) is queried for their timeout/error counts. Any
    timeouts or errors which have occurred are written to a log line formatted
    as follows (for example):

    ---

        2013-02-20 14:31:23,916 client1_46.4.112.56_7086_io_timeouts:10 client1_46.4.121.213_7086_io_timeouts:11

    ---

    (where "client1", in this example, is the name of a registered client.)

    Copyright:      Copyright (c) 2013-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.util.log.ClientStats;



/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.io.select.EpollSelectDispatcher;

import ocean.io.select.client.TimerEvent;

import ocean.util.log.Appender;

import ocean.util.log.Stats;

import ocean.text.convert.Layout;

import swarm.Const : NodeItem;

import swarm.client.model.IClient;

import swarm.client.connection.model.INodeConnectionPoolInfo;

import swarm.client.registry.model.IFluidNodeRegistryInfo;

import core.stdc.time : time_t;

import ocean.transition;

/*******************************************************************************

    Multi-swarm client error/timeout stats logger.

*******************************************************************************/

public class ClientStats : StatsLog
{
    /***************************************************************************

        Set of clients to be logged, indexed by an identifier string.

        This member is public and is expected to be modified from the outside
        (the clients which are required to be logged should be added to the
        array).

    ***************************************************************************/

    public IClient[istring] clients;


    /***************************************************************************

        Queue request threshold controls at what percentage full the request
        queue is before its size is logged. Set by the application.

        Defaults to 2.0 (200%) where the queue size will never be logged. Must
        be set to 1.0 or lower for the queue size to be logged.

    ***************************************************************************/

    public float queued_requests_threshold = 2.0;


    /***************************************************************************

        Write period

    ***************************************************************************/

    private time_t period;


    /***************************************************************************

        Default value of write period

    ***************************************************************************/

    private const time_t default_period = 5;


    /***************************************************************************

        Timer which fires to write log output.

    ***************************************************************************/

    private TimerEvent timer;


    /***************************************************************************

        String formatting buffer.

    ***************************************************************************/

    private mstring buf;


    /***************************************************************************

        Construct the class to use the default StatsLog appender and starts the
        update timer.

        Params:
            epoll = epoll select dispatcher to register timer with
            file_name = log file to write to
            period = seconds delay between log writes

    ***************************************************************************/

    public this ( EpollSelectDispatcher epoll, istring file_name,
        time_t period = default_period )
    {
        this(epoll, file_name, null, period);
    }


    /***************************************************************************

        Construct the class to use the provided appender with StatsLog and
        starts the update timer. If the appender is null the default Statslog
        appender is used.

        Params:
            epoll = epoll select dispatcher to register timer with
            file_name = log file to write to
            appender = delegate which returns appender instances to be used in
                the Statslog. The delegate parameter file says where to log to
                and layout defines the format of the message. If this parameter
                is null the default Statslog appender is used.
            period = seconds delay between log writes

    ***************************************************************************/

    public this ( EpollSelectDispatcher epoll, istring file_name,
        Appender delegate ( istring file, Appender.Layout layout ) appender,
        time_t period = default_period )
    {
        if ( appender is null )
        {
            super(new StatsLog.Config(file_name), "SwarmClientStats");
        }
        else
        {
            super(new StatsLog.Config(file_name), appender, "SwarmClientStats");
        }

        this.period = period;

        this.timer = new TimerEvent(&this.write);
        epoll.register(timer);
        timer.set(5, 0, period, 0);
    }


    /***************************************************************************

        Timer delegate. Writes a line to the logfile detailing, for each
        registered client:
            * IO errors
            * IO timeouts
            * Connection timeouts
            * Fraction of request queue full
            * Overflowed requests (when client has an overflow plugin)
            * Disabled nodes (when client has a fluid node registry)

        Once queried, the timeout/error counters in the clients are reset.

    ***************************************************************************/

    private bool write ( )
    {
        this.layout.length = 0;

        this.appendSection!("err")(( IClient client, cstring id, ref bool add_separator )
            {
                this.appendNodeInfoValue!("error_count")
                    (client, id, add_separator);
            });

        this.appendSection!("io_to")(( IClient client, cstring id, ref bool add_separator )
            {
                this.appendNodeInfoValue!("io_timeout_count")
                    (client, id, add_separator);
            });

        this.appendSection!("conn_to")(( IClient client, cstring id, ref bool add_separator )
            {
                this.appendNodeInfoValue!("conn_timeout_count")
                    (client, id, add_separator);
            });

        this.appendSection!("queue")(( IClient client, cstring id, ref bool add_separator )
            {
                this.appendQueueFullness(client, id, add_separator);
            });

        this.appendSection!("overflow")(( IClient client, cstring id, ref bool add_separator )
            {
                this.appendNodeInfoValue!("overflowed_requests")
                    (client, id, add_separator);
            });

        this.appendSection!("disabled")(( IClient client, cstring id, ref bool add_separator )
            {
                this.appendDisabled(client, id, add_separator);
            });

        this.logger.info(this.layout[]);

        this.resetClientCounters();

        return true;
    }


    /***************************************************************************

        Appends a section containing a single type of stat for all registered
        clients to the log line.

        Sections appear in the log line as follows:
            "desc: [<client1_value> <client1_value> <client2_value> <client2_value>]"

        where each client's set of values are written as a result of calling the
        provided append_client delegate once.

        Template params:
            desc = string specifying the description of the section to be
                written to the log line

        Params:
            append_client = delegate to be called once per registered client.
                The delegate is passed the client reference, its name, and a
                flag to indicate whether a ' ' character should be appended
                before the next value

    ***************************************************************************/

    private void appendSection ( istring desc ) ( void delegate ( IClient client,
        cstring id, ref bool add_separator ) append_client )
    {
        bool add_separator;

        this.layout(desc ~ ": [");
        foreach ( name, client; this.clients )
        {
            append_client(client, name, add_separator);
        }
        this.layout("] ");
    }


    /***************************************************************************

        Appends a value from the node info interfaces of the nodes in the
        specified client's registry to the log line.

        Template params:
            field = string specifying the name of the field of
                INodeConnectionPoolInfo to be logged

        Params:
            client = client to log
            id = name of client being logged (appended to the names of the
                values written to the log line)
            add_separator = if true, a space is added before each value. Set to
                true after the first value has been written

    ***************************************************************************/

    private void appendNodeInfoValue ( istring field ) ( IClient client,
        cstring id, ref bool add_separator )
    {
        foreach ( node_info; client.nodes )
        {
            auto v = mixin("node_info." ~ field);
            if ( v > 0 )
            {
                this.logValue(node_info, id, v, add_separator);
            }
        }
    }


    /***************************************************************************

        Appends the fullness fraction of the specified client's request queues
        to the log line.

        Params:
            client = client to log
            id = name of client being logged (appended to the names of the
                values written to the log line)
            add_separator = if true, a space is added before each value. Set to
                true after the first value has been written

    ***************************************************************************/

    private void appendQueueFullness ( IClient client, cstring id,
        ref bool add_separator )
    {
        if ( client.nodes.queue_limit == 0 ) return;

        foreach ( node_info; client.nodes )
        {
            float queue_fraction = cast(float)node_info.queued_bytes /
                cast(float)client.nodes.queue_limit;

            if ( queue_fraction >= this.queued_requests_threshold )
            {
                this.logValue(node_info, id, queue_fraction, add_separator);
            }
        }
    }


    /***************************************************************************

        For clients with a fluid node registry, appends disabled nodes in the
        specified client's registry to the log line.

        Params:
            client = client to log
            id = name of client being logged (appended to the names of the
                values written to the log line)
            add_separator = if true, a space is added before each value. Set to
                true after the first value has been written

    ***************************************************************************/

    private void appendDisabled ( IClient client, cstring id,
        ref bool add_separator )
    {
        auto fluid_nodes = cast(IFluidNodeRegistryInfo)client.nodes;
        if ( fluid_nodes is null || fluid_nodes.num_disabled() == 0 ) return;

        fluid_nodes.disabled_nodes((IFluidNodeRegistryInfo.IDisabledIterator it)
            {
                foreach ( node_item, node_info; it )
                {
                    this.logNode(node_info, id, add_separator);
                }
            });
    }


    /***************************************************************************

        Resets the error/timeout counters kept by the node connection pools of
        all registered clients.

    ***************************************************************************/

    private void resetClientCounters ( )
    {
        foreach ( name, client; this.clients )
        {
            foreach ( node_info; client.nodes )
            {
                node_info.resetCounters();
            }
        }
    }


    /***************************************************************************

        Writes the specified field to the log, with the format:
            <client id>_<node address>_<node port>:<value>

        Params:
            node_info = node connection to log
            id = name of client being logged
            value = the value to be logged
            add_separator = if true, a space is added before each value. Set to
                true after the first value has been written

    ***************************************************************************/

    private void logValue ( T ) ( INodeConnectionPoolInfo node_info, cstring id,
        T value, ref bool add_separator )
    {
        this.logNode(node_info, id, add_separator);

        this.layout(':', value);
    }


    /***************************************************************************

        Writes the specified node's identifier to the log, with the format:
            <client id>_<node address>_<node port>

        Params:
            node_info = node connection to log
            id = name of client being logged
            add_separator = if true, a space is added before each value. Set to
                true after the first value has been written

    ***************************************************************************/

    private void logNode ( INodeConnectionPoolInfo node_info, cstring id,
        ref bool add_separator )
    {
        if ( add_separator )
        {
            this.layout(' ');
        }

        this.layout(id, "_", node_info.address, "_", node_info.port);

        add_separator = true;
    }
}
