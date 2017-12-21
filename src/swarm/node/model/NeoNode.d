/*******************************************************************************

    Swarm node base class with dual protocol support (neo & legacy)

    Base class for a swarm node with the following features:
        * Contains a SelectListener which handles incoming connections.
        * Has an eventLoop() method to start the server, and a shutdown() method
          to stop the server.

    copyright:      Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.node.model.NeoNode;



/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.transition;

import swarm.Const : NodeItem;
import swarm.neo.AddrPort;

import swarm.node.model.INode;
import swarm.node.model.INodeInfo;
import swarm.node.model.ISwarmConnectionHandlerInfo;
import swarm.node.model.RecordActionCounters;

import swarm.node.connection.ConnectionHandler;
import Neo = swarm.neo.node.ConnectionHandler;

import swarm.node.request.RequestStats;

import ocean.net.server.connection.IConnectionHandler;

import ocean.sys.socket.AddressIPSocket;
import ocean.sys.socket.InetAddress;

import ocean.io.select.client.model.ISelectClient : IAdvancedSelectClient;

import ocean.io.select.EpollSelectDispatcher;
import ocean.net.server.SelectListener;

import ocean.io.compress.lzo.LzoChunkCompressor;

import ocean.util.container.pool.model.IAggregatePool;

import ocean.util.log.Logger;

import ocean.core.Enforce;

/*******************************************************************************

    Static module logger

*******************************************************************************/

static private Logger log;
static this ( )
{
    log = Log.lookup("swarm.node.model.NeoNode");
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

        Select listener instances

     **************************************************************************/

    private ISelectListener listener, neo_listener, unix_listener;


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

        AddrPort that Neo's listener is binded to.

    ***************************************************************************/

    private AddrPort neo_address_;

    /***************************************************************************

        Per-request stats tracker.

    ***************************************************************************/

    private RequestStats request_stats_;


    /***************************************************************************

        Per-request neo stats tracker.

    ***************************************************************************/

    private RequestStats neo_request_stats_;


    /***************************************************************************

        Constructor

        Params:
            node = node addres & port
            conn_setup_params = connection handler constructor arguments
            listener = select listener, is evaluated exactly once after
                       conn_setup_params have been populated
            neo_listener = select listener to handle the neo protocol
            unix_listener = select listener to handle control requests through
                the Unix domain server socket

    ***************************************************************************/

    public this ( NodeItem node, ConnectionSetupParams conn_setup_params,
                  lazy ISelectListener listener,
                  ISelectListener neo_listener = null,
                  ISelectListener unix_listener = null )
    {
        this.node_item_ = node;

        this.request_stats_ = new RequestStats;
        this.neo_request_stats_ = new RequestStats;

        conn_setup_params.error_dg = &this.error;

        this.listener = listener;
        this.neo_listener = neo_listener;
        this.unix_listener = unix_listener;

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

    public void error_callback ( scope ErrorDg error_dg )
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

        if (this.neo_listener)
            this.neo_listener.connection_limit(max);
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


    /**************************************************************************

        Returns:
            the limit of the number of neo connections (i.e. the maximum number
            of connections the node can handle in parallel) or 0 if limitation
            is disabled or no neo listener exists

     **************************************************************************/

    override public size_t neo_connection_limit ( )
    {
        if (this.neo_listener)
            return cast(size_t)this.neo_listener.connection_limit;
        else
            return 0;
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

        if (this.neo_listener)
            epoll.register(this.neo_listener);

        if (this.unix_listener)
            epoll.register(this.unix_listener);
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

        if (this.neo_listener)
        {
            epoll.unregister(this.neo_listener);
            this.neo_listener.shutdown;
        }

        if (this.unix_listener)
        {
            epoll.unregister(this.unix_listener);
            this.unix_listener.shutdown;
        }
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


    /***************************************************************************

        Returns:
            the number of neo connections in the pool

    ***************************************************************************/

    override public size_t num_neo_connections ( )
    {
        if (this.neo_listener)
            return this.neo_listener.poolInfo.length();
        else
            return 0;
    }


    /***************************************************************************

        Returns:
             the number of active neo connections being handled

    ***************************************************************************/

    override public size_t num_open_neo_connections ( )
    {
        if (this.neo_listener)
            return this.neo_listener.poolInfo.num_busy();
        else
            return 0;
    }


    /**************************************************************************

        Increments the count of received bytes by the specified amount.

        Params:
            bytes = number of bytes received

     **************************************************************************/
// TODO: hook neo connection in with these functions
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
            per-request neo stats tracking instance

    ***************************************************************************/

    override public RequestStats neo_request_stats ( )
    {
        return this.neo_request_stats_;
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

        Returns:
            IPAdress containing info on which address/port Neo node is
            listening.

    ***************************************************************************/

    public AddrPort neo_address ( )
    {
        return this.neo_address_;
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

*******************************************************************************/

public class NodeBase ( ConnHandler : ISwarmConnectionHandler ) : INodeBase
{
    import ocean.net.server.unix.UnixListener;
    import ocean.net.server.unix.UnixConnectionHandler;
    import swarm.neo.authentication.NodeCredentials;
    import swarm.neo.authentication.HmacDef : Key;

    /***************************************************************************

        Select listener aliases

    ***************************************************************************/

    public alias SelectListener!(ConnHandler, ConnectionSetupParams) Listener;
    public alias SelectListener!(Neo.ConnectionHandler, Neo.ConnectionHandler.SharedParams) NeoListener;

    /***************************************************************************

        Settings required by the constructor and the neo connection handlers.

    ***************************************************************************/

    public static struct Options
    {
        /***********************************************************************

            Map of command codes -> request handling info.

        ***********************************************************************/

        public Neo.ConnectionHandler.RequestMap requests;

        /// Alias to old name.
        deprecated("Use the `requests` member instead.")
        public alias requests cmd_handlers;

        /***********************************************************************

            Epoll instance used by the node.

        ***********************************************************************/

        public EpollSelectDispatcher epoll;

        /***********************************************************************

            Opaque shared resources instance passed to the request handlers.

        ***********************************************************************/

        public Object shared_resources;

        /***********************************************************************

            Flag controlling whether Nagle's algorithm is disabled (true) or
            left enabled (false) on the underlying socket.

            (The no-delay option is not generally suited to live servers, where
            efficient packing of packets is desired, but can be useful for
            low-bandwidth test setups.)

        ***********************************************************************/

        public bool no_delay;

        /***********************************************************************

            Unix domain server socket path. (If null, no unix socket will be
            opened.)

        ***********************************************************************/

        public istring unix_socket_path;

        /***********************************************************************

            The name of the credentials file to read from. If null, the
            `credentials_map` field must be set with a pre-defined credentials
            map.

        ***********************************************************************/

        public istring credentials_filename;

        /***********************************************************************

            Map of auth names -> keys, only used if `credentials_filename` is
            null.

        ***********************************************************************/

        public Key[istring] credentials_map;
    }

    /***************************************************************************

        Server select listener

    ***************************************************************************/

    private Listener listener;


    /***************************************************************************

        Server neo select listener

    ***************************************************************************/

    private NeoListener neo_listener;


    /***************************************************************************

        The server socket.

    ***************************************************************************/

    private AddressIPSocket!() socket;
    private AddressIPSocket!() neo_socket;

    /***************************************************************************

        The credentials file.

    ***************************************************************************/

    private Credentials credentials_file;

    /***************************************************************************

        Constructor

        Params:
            node = node addres & port
            neo_port = port of neo listener (same address as above)
            conn_setup_params = connection handler constructor arguments
            options = options for the neo node and connection handlers
            backlog = (see ISelectListener ctor)

    ***************************************************************************/

    public this ( NodeItem node, ushort neo_port,
                  ConnectionSetupParams conn_setup_params, Options options,
                  int backlog )
    {
        assert(options.epoll !is null);

        InetAddress!(false) addr, neo_addr;
        alias SelectListener!(Neo.ConnectionHandler,
            Neo.ConnectionHandler.SharedParams) NeoListener;

        // Create listener sockets.
        this.socket = new AddressIPSocket!();
        this.neo_socket = new AddressIPSocket!();

        // Load credentials from specified file.
        Const!(Key[istring])* credentials;
        if ( options.credentials_filename )
        {
            assert(options.credentials_map is null);
            this.credentials_file =
                new Credentials(options.credentials_filename);
            credentials = this.credentials_file.credentials;
        }
        // ...or copy the pre-configured credentials.
        else
        {
            assert(options.credentials_map !is null);

            // Make sure the reference to the credentials map does not go out
            // of scope. (Store a copy in heap-allocated memory.)
            static struct S { Key[istring] cred; }
            auto s = new S;
            s.cred = options.credentials_map;
            credentials = &s.cred;
        }

        // Instantiate params object shared by all neo connection handlers.
        auto neo_conn_setup_params = new Neo.ConnectionHandler.SharedParams(
            options.epoll, options.shared_resources, options.requests,
            options.no_delay, *credentials, this);

        // Set up unix listener socket, if specified.
        UnixListener unix_listener;
        if ( options.unix_socket_path.length )
        {
            BasicCommandHandler.Handler[istring] unix_socket_handlers;
            if ( this.credentials_file )
            {
                unix_socket_handlers =
                    ["update-credentials": &this.handleUpdateCredentials];
            }

            unix_listener = new UnixListener(
                options.unix_socket_path, options.epoll, unix_socket_handlers);
        }

        // Super ctor.
        super(node, conn_setup_params,
            this.listener = new Listener(
                addr(node.Address, node.Port), this.socket, conn_setup_params,
                backlog
            ),
            this.neo_listener = new NeoListener(
                neo_addr(node.Address, neo_port), this.neo_socket,
                neo_conn_setup_params, backlog
            ),
            unix_listener
        );

        // Set up stats tracking for all named requests specified.
        options.requests.initStats(this.neo_request_stats);

        // Copy actual bound ports into class members.
        enforce(this.socket.updateAddress() == 0, "socket.updateAddress() failed!");
        enforce(this.neo_socket.updateAddress() == 0, "socket.updateAddress() failed!");

        this.node_item_.Port = this.socket.port();
        this.neo_address_.setAddress(this.neo_socket.address());
        this.neo_address_.port(this.neo_socket.port());
    }

    /**************************************************************************

        Returns:
            number of bytes received

        Note: as the neo connections already have their own stats tracking, we
        just read that out here. super.receivedBytes() is not called from neo
        connections.

     **************************************************************************/

    override public ulong bytes_received ( )
    {
        ulong ret = super.bytes_received();

        foreach ( conn_info; this.neo_listener.poolInfo() )
        {
            auto conn = cast(Neo.ConnectionHandler)conn_info;
            assert(conn !is null);

            ret += conn.bytes_received;
        }

        return ret;
    }


    /**************************************************************************

        Returns:
            number of bytes sent

        Note: as the neo connections already have their own stats tracking, we
        just read that out here. super.sentBytes() is not called from neo
        connections.

     **************************************************************************/

    override public ulong bytes_sent ( )
    {
        ulong ret = super.bytes_sent();

        foreach ( conn_info; this.neo_listener.poolInfo() )
        {
            auto conn = cast(Neo.ConnectionHandler)conn_info;
            assert(conn !is null);

            ret += conn.bytes_sent;
        }

        return ret;
    }

    /***************************************************************************

        Unix domain socket connection handler, updates the credentials.

        Params:
            args          = command arguments
            send_response = delegate to write to the client socket

    ***************************************************************************/

    private void handleUpdateCredentials ( cstring args,
        scope void delegate ( cstring response ) send_response )
    in
    {
        assert(this.credentials_file);
    }
    body
    {
        if (args.length)
        {
            send_response("Error: No command arguments expected\n");
            return;
        }

        try
        {
            this.credentials_file.update();
            send_response("Credentials updated.\n");
        }
        catch (Exception e)
        {
            send_response("Error updating credentials: ");
            send_response(getMsg(e));
            send_response("\n");
        }
    }

    /***************************************************************************

        Constructor

        Params:
            node = node addres & port
            conn_setup_params = connection handler constructor arguments
            backlog = (see ISelectListener ctor)

    ***************************************************************************/

    public this ( NodeItem node, ConnectionSetupParams conn_setup_params,
                  int backlog )
    {
        InetAddress!(false) addr;

        this.socket = new AddressIPSocket!();
        super(node, conn_setup_params,
            this.listener = new Listener(
                addr(node.Address, node.Port), this.socket, conn_setup_params,
                backlog
            )
        );

        enforce(this.socket.updateAddress() == 0, "socket.updateAddress() failed!");
    }


    /***************************************************************************

        Writes connection information to log file.

    ***************************************************************************/
    // TODO: adapt to log neo connections too? (I'm not sure if this is used)
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
        public this (scope void delegate(IConnectionHandler) a, ConnectionSetupParams b)
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
