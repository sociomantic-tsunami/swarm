/*******************************************************************************

    Swarm node base class

    Base class for a swarm node with the following features:
        * Contains a SelectListener which handles incoming connections.
        * Has an eventLoop() method to start the server, and a shutdown() method
          to stop the server.

    copyright:      Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.node.model.Node;



/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.transition;

import swarm.Const : NodeItem;

import swarm.node.model.INode;
import swarm.node.model.INodeInfo;
import swarm.node.model.ISwarmConnectionHandlerInfo;
import swarm.node.model.RecordActionCounters;

import swarm.node.connection.ConnectionHandler;

import swarm.node.request.RequestStats;

import ocean.net.server.connection.IConnectionHandler;

import ocean.sys.socket.AddressIPSocket;
import ocean.sys.socket.InetAddress;

import ocean.io.select.client.model.ISelectClient : IAdvancedSelectClient;

import ocean.io.select.EpollSelectDispatcher;
import ocean.net.server.SelectListener;

import ocean.io.compress.lzo.LzoChunkCompressor;

import ocean.util.container.pool.model.IAggregatePool;

import ocean.util.log.Log;

import ocean.core.Enforce;

/*******************************************************************************

    Static module logger

*******************************************************************************/

static private Logger log;
static this ( )
{
    log = Log.lookup("swarm.node.model.Node");
}



/*******************************************************************************

    Node base class.

*******************************************************************************/

public abstract class INodeBase : INode, INodeInfo
{
    /***************************************************************************

        Type aliases for derived classes

    ***************************************************************************/

    protected alias .NodeItem NodeItem;
    protected alias .EpollSelectDispatcher EpollSelectDispatcher;


    /***************************************************************************

        Select listener instance

     **************************************************************************/

    private ISelectListener listener;


    /***************************************************************************

        User provided error callback delegate - called when an error occurs
        while executing an i/o handler. This can happen in two cases:

            1. When a client disconnects. This is usually valid, and means that
               the client doesn't need to make any further queue requests.

            2. When something seriously wrong has happened during i/o. In this
               case there's nothing we can do to rescue the command that was in
               process, but at least the node application can be notified that
               this has happened.

     **************************************************************************/

    public alias IConnectionHandler.ErrorDg ErrorDg;

    private ErrorDg error_dg;


    /**************************************************************************

        Count of bytes received & sent.

     **************************************************************************/

    private ulong bytes_received_, bytes_sent_;


    /**************************************************************************

        Record action counters.

     **************************************************************************/

    private RecordActionCounters record_action_counters_;


    /**************************************************************************

        Count of records handled.

        To be removed together with records_handled() and handledRecord().

     **************************************************************************/

    private ulong records_handled_;


    /***************************************************************************

        Node item struct, containing node address and port.

    ***************************************************************************/

    private NodeItem node_item_;


    /***************************************************************************

        Per-request stats tracker.

    ***************************************************************************/

    private RequestStats request_stats_;


    /***************************************************************************

        Constructor

        Params:
            node = node addres & port
            conn_setup_params = connection handler constructor arguments
            listener = select listener, is evaluated exactly once after
                       conn_setup_params have been populated

    ***************************************************************************/

    public this ( NodeItem node, ConnectionSetupParams conn_setup_params,
                  lazy ISelectListener listener )
    {
        this.node_item_ = node;

        this.request_stats_ = new RequestStats;

        conn_setup_params.error_dg = &this.error;

        this.listener = listener;

        this.record_action_counters_ = new RecordActionCounters(this.record_action_counter_ids);
    }


    /**************************************************************************

        Sets the error callback delegate.

        The error delegate is of type:

            void delegate ( Exception, IAdvancedSelectClient.EventInfo,
                IConnectionHandlerInfo )

        Params:
            error_dg = delegate to be called on error during handling a
                connection

     **************************************************************************/

    public void error_callback ( ErrorDg error_dg )
    {
        this.error_dg = error_dg;
    }


    /**************************************************************************

        Sets the node's connection limit.

        Params:
            max = maximum allowed number of connections to be handled at once

     **************************************************************************/

    public void connection_limit ( uint max )
    {
        this.listener.connection_limit(max);
    }


    /**************************************************************************

        Returns:
            the limit of the number of connections (i.e. the maximum number of
            connections the node can handle in parallel) or 0 if limitation is
            disabled

     **************************************************************************/

    override public size_t connection_limit ( )
    {
        return cast(size_t)this.listener.connection_limit;
    }


    /***************************************************************************

        Registers any selectables in the node (including the listener) with the
        provided epoll selector.

        Params:
            epoll = epoll selector to register with

    ***************************************************************************/

    public void register ( EpollSelectDispatcher epoll )
    {
        epoll.register(this.listener);
    }


    /***************************************************************************

        Flushes write buffers of stream connections.

    ***************************************************************************/

    public void flush ( )
    {
        // TODO: is this needed in channel-less base?
    }


    /***************************************************************************

        Shuts down the listener and all connections.

    ***************************************************************************/

    public void stopListener ( EpollSelectDispatcher epoll )
    {
        epoll.unregister(this.listener);
        this.listener.shutdown;
    }


    /***************************************************************************

        Shuts down the node. The base implementation does nothing.

    ***************************************************************************/

    public void shutdown ( )
    {
    }


    /**************************************************************************

        Returns:
            the number of connections in the pool

     **************************************************************************/

    override public size_t num_connections ( )
    {
        return this.listener.poolInfo.length();
    }


    /**************************************************************************

        Returns:
             the number of active connections being handled

     **************************************************************************/

    override public size_t num_open_connections ( )
    {
        return this.listener.poolInfo.num_busy();
    }


    /**************************************************************************

        Increments the count of received bytes by the specified amount.

        Params:
            bytes = number of bytes received

     **************************************************************************/

    override public void receivedBytes ( size_t bytes )
    {
        this.bytes_received_ += bytes;
    }


    /**************************************************************************

        Increments the count of sent bytes by the specified amount.

        Params:
            bytes = number of bytes sent

     **************************************************************************/

    override public void sentBytes ( size_t bytes )
    {
        this.bytes_sent_ += bytes;
    }


    /**************************************************************************

        Returns:
            number of bytes received

     **************************************************************************/

    override public ulong bytes_received ( )
    {
        return this.bytes_received_;
    }


    /**************************************************************************

        Returns:
            number of bytes sent

     **************************************************************************/

    override public ulong bytes_sent ( )
    {
        return this.bytes_sent_;
    }

    /**************************************************************************

        Obtains the record action counters. A subclass specifies the counter
        identifiers by returning them from record_action_counter_ids().

        Returns:
            the record action counters.

     **************************************************************************/

    override public RecordActionCounters record_action_counters ( )
    {
        return this.record_action_counters_;
    }


    /**************************************************************************

        Resets the count of received / sent bytes and the record action
        counters.

     **************************************************************************/

    override public void resetCounters ( )
    {
        this.bytes_received_ = 0;
        this.bytes_sent_ = 0;
        this.records_handled_ = 0;
        this.record_action_counters_.reset();
    }


    /***************************************************************************

        Returns:
            per-request stats tracking instance

    ***************************************************************************/

    override public RequestStats request_stats ( )
    {
        return this.request_stats_;
    }


    /***************************************************************************

        Returns:
            Node item struct, containing node address, port & hash range.

    ***************************************************************************/

    public NodeItem node_item ( )
    {
        return this.node_item_;
    }


    /***************************************************************************

        Specifies the identifiers for the record action counters to create.

        By default no record action counters are created; override this method
        to create them.

        Returns:
            the identifiers for the record action counters to create.

    ***************************************************************************/

    protected istring[] record_action_counter_ids ( )
    {
        return null;
    }


    /***************************************************************************

        Returns:
            identifier string for this node

    ***************************************************************************/

    abstract protected cstring id ( );


    /**************************************************************************

        Called upon occurrence of an i/o error. In turn calls the user provided
        error delegate, if one exists.

        Params:
            exception = exception which occurred
            event = select event during which the exception occurred

     **************************************************************************/

    private void error ( Exception exception, IAdvancedSelectClient.Event event,
        ISwarmConnectionHandlerInfo.IConnectionHandlerInfo conn )
    {
        if ( this.error_dg )
        {
            this.error_dg(exception, event, conn);
        }
    }
}



/*******************************************************************************

    Node base template.

    Template params:
        ConnHandler = type of connection handler (the node contains a
            SelectListener instance which owns a pool of instances of this type)
        Setup       = type of connection setup parameters, must be a
            ConnectionSetupParams subclass.

*******************************************************************************/

public class NodeBase ( ConnHandler : ISwarmConnectionHandler,
                        Setup : ConnectionSetupParams = ConnectionSetupParams ) : INodeBase
{
    /***************************************************************************

        Select listener alias

    ***************************************************************************/

    public alias SelectListener!(ConnHandler, Setup) Listener;


    /***************************************************************************

        Server select listener

    ***************************************************************************/

    private Listener listener;

    /***************************************************************************

        The server socket.

    ***************************************************************************/

    private AddressIPSocket!() socket;

    /***************************************************************************

        Constructor

        Params:
            node = node addres & port
            conn_setup_params = connection handler constructor arguments
            backlog = (see ISelectListener ctor)

    ***************************************************************************/

    public this ( NodeItem node, Setup conn_setup_params, int backlog )
    {
        InetAddress!(false) addr;

        this.socket = new AddressIPSocket!();
        this.listener = new Listener(addr(node.Address, node.Port),
            this.socket, conn_setup_params, backlog);

        enforce(this.socket.updateAddress() == 0, "socket.updateAddress() failed!");

        node.Port = this.socket.port();
        super(node, conn_setup_params, this.listener);
    }


    /***************************************************************************

        Constructor

        Params:
            port = node port (uses local address)
            conn_setup_params = connection handler constructor arguments
            backlog = (see ISelectListener ctor)

    ***************************************************************************/

    public this ( ushort port, Setup conn_setup_params, int backlog )
    {
        NodeItem node;
        node.Port = port;

        InetAddress!(false) addr;

        this.socket = new AddressIPSocket!();
        this.listener = new Listener(addr(node.Port), this.socket, conn_setup_params,
            backlog);

        enforce(this.socket.updateAddress() == 0, "socket.updateAddress() failed!");

        super(node, conn_setup_params, this.listener);
    }


    /***************************************************************************

        Writes connection information to log file.

    ***************************************************************************/

    public void connectionLog ( )
    {
        auto conns = this.listener.poolInfo;

        log.info("Connections: {} open, {} spare in pool",
            conns.num_busy, conns.num_idle);

        foreach ( i, conn; conns )
        {
            auto swarm_conn = cast(ISwarmConnectionHandlerInfo)conn;
            assert(swarm_conn, "Node connection handler does not implement ISwarmConnectionHandlerInfo");

            auto client = swarm_conn.registered_client;
            auto events = client ? client.events : 0;

            debug
            {
                auto id = client ? client.id : "none";
                log.info("{}: fd={}, remote={}:{}, cmd={}, had_io={}, events={}, reg={}",
                    i, conn.fileHandle, swarm_conn.address,
                    swarm_conn.port, swarm_conn.command, swarm_conn.had_io,
                    events, id);
            }
            else
            {
                log.info("{}: fd={}, remote={}:{}, cmd={}, had_io={}, events={}",
                    i, conn.fileHandle, swarm_conn.address,
                    swarm_conn.port, swarm_conn.command, swarm_conn.had_io,
                    events);
            }
        }
    }
}


version (UnitTest)
{
    private class TestConnectionHandler : ISwarmConnectionHandler
    {
        public this (void delegate(IConnectionHandler) a, ConnectionSetupParams b)
        {
            super(a, b);
        }
        override protected void handleCommand () {}
    }
}

unittest
{
    alias NodeBase!(TestConnectionHandler) Instance;
}
