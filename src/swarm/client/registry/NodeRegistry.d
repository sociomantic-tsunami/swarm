/*******************************************************************************

    Client node connection registry

    copyright:      Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.registry.NodeRegistry;



/*******************************************************************************

    Imports

*******************************************************************************/

import swarm.Const : NodeItem;

import swarm.client.model.ClientSettings;

import swarm.client.ClientExceptions;

import swarm.client.registry.model.INodeRegistry;
import swarm.client.registry.model.INodeRegistryInfo;
import swarm.client.registry.NodeSet;
import swarm.client.registry.FlushableSet;

import swarm.client.connection.model.INodeConnectionPool;
import swarm.client.connection.model.INodeConnectionPoolInfo;
import swarm.client.connection.model.INodeConnectionPoolErrorReporter;

import swarm.client.connection.NodeConnectionPool;
import swarm.client.connection.RequestOverflow;

import swarm.client.ClientCommandParams;

import ocean.core.Enforce;

import ocean.io.select.EpollSelectDispatcher;

import ocean.transition;


/*******************************************************************************

    Connection registry base class

*******************************************************************************/

public abstract class NodeRegistry : INodeRegistry
{
    /***************************************************************************

        Local alias type redefinitions

    ***************************************************************************/

    protected alias .EpollSelectDispatcher EpollSelectDispatcher;

    protected alias .IRequestOverflow IRequestOverflow;

    protected alias .NodeConnectionPool NodeConnectionPool;

    protected alias .ClientCommandParams ClientCommandParams;

    protected alias .NodeSet NodeSet;

    protected alias .INodeConnectionPoolErrorReporter INodeConnectionPoolErrorReporter;

    protected alias .ClientSettings ClientSettings;


    /***************************************************************************

        Settings for the client

    ***************************************************************************/

    protected ClientSettings settings;


    /***************************************************************************

        Connection pools in registry.

    ***************************************************************************/

    protected NodeSet nodes;


    /***************************************************************************

        Request overflow handler -- decides what to do with a newly assigned
        request when the request queue for the appropriate node is full. (Used
        by the connection pool instances themselves, and stored here in order
        to pass to them as they are created.)

    ***************************************************************************/

    protected IRequestOverflow request_overflow;


    /***************************************************************************

        Registry exception instance.

    ***************************************************************************/

    protected NoResponsibleNodeException no_node_exception;


    /***************************************************************************

        Epoll select dispatcher shared by all connections and request handlers,
        passed as a reference to the constructor.

    ***************************************************************************/

    protected EpollSelectDispatcher epoll;


    /***************************************************************************

        Error reporter

    ***************************************************************************/

    protected INodeConnectionPoolErrorReporter error_reporter;


    /***************************************************************************

        Set of IFlushable instances, which should be flushed when the Flush
        client command is assigned (see assignClientCommand() in
        NodeRegistryTemplate).

    ***************************************************************************/

    protected FlushableSet flushables;


    /***************************************************************************

        Constructor

        Params:
            epoll = selector dispatcher instance to register the socket and I/O
                events
            settings = client settings instance
            request_overflow = overflow handler for requests which don't fit in
                the request queue
            nodes = NodeSet-derived class to manage the set of registered nodes
            error_reporter = error reporter instance to notify on error or
                timeout

    ***************************************************************************/

    public this ( EpollSelectDispatcher epoll, ClientSettings settings,
        IRequestOverflow request_overflow, NodeSet nodes,
        INodeConnectionPoolErrorReporter error_reporter )
    {
        assert(&settings); // call ClientSettings invariant
        assert(epoll !is null, "epoll must be non-null");

        this.epoll = epoll;
        this.settings = settings;
        this.nodes = nodes;
        this.error_reporter = error_reporter;

        this.no_node_exception = new NoResponsibleNodeException;

        this.flushables = new FlushableSet(100);

        this.request_overflow = request_overflow;
    }


    /***************************************************************************

        Adds a node connection to the registry.

        Params:
            address = node address
            port = node service port

        Throws:
            if the specific node (address/port combination) already exists in
            the registry

    ***************************************************************************/

    public void add ( mstring address, ushort port )
    out
    {
        assert(this.inRegistry(address, port), "node not in registry after add()");
    }
    body
    {
        this.nodes.add(NodeItem(address, port),
            this.newConnectionPool(address, port));
    }


    /***************************************************************************

        Adds a request to one or more nodes. If the request specified in the
        provided params should be sent to all nodes simultaneously, then it is
        added to all nodes in the registry. Otherwise, the abstract method
        getResponsiblePool() is called to determine which node the request
        should be added to.

        Params:
            params = request parameters
            error_dg = delegate to be called if an exception is thrown while
                assigning a request. This delegate may be called multiple times
                for requests which make multiple assignments (to more than one
                node, for example)

        Throws:
            if no node responsible for the request can be found

    ***************************************************************************/

    public void assign ( IRequestParams params, AssignErrorDg error_dg )
    {
        if ( params.isClientCommand() )
        {
            auto handled =
                this.assignClientCommand(this.getClientCommandParams(params));
            assert(handled, "unhandled client command code");
        }
        else
        {
            enforce(this.no_node_exception, this.nodes.list.length);

            if ( this.allNodesRequest(params) )
            {
                foreach ( connpool; this.nodes.list )
                {
                    this.assignToNode(params, error_dg, connpool);
                }
            }
            else
            {
                auto pool = this.getResponsiblePool(params);
                enforce(this.no_node_exception, pool);

                this.assignToNode(params, error_dg, pool);
            }
        }
    }


    /***************************************************************************

        Adds a request to the individual node specified (via the protected
        assignToNode_()). Any exceptions thrown by the assignment are caught and
        passed to the provided error handler.

        Params:
            params = request parameters
            error_dg = delegate to be called if an exception is thrown while
                assigning the request
            node_conn_pool = node connection pool to assign request to

    ***************************************************************************/

    private void assignToNode ( IRequestParams params, AssignErrorDg error_dg,
        NodeConnectionPool node_conn_pool )
    {
        try
        {
            this.assignToNode_(params, node_conn_pool);
        }
        catch ( Exception e )
        {
            error_dg(params, e);
        }
    }


    /***************************************************************************

        Adds a request to the individual node specified. The default method
        simply calls NodeConnectionPool.assign(), but derived classes may
        override to implement additional behaviour. The method should throw upon
        error -- the caller catches and handles exceptions.

        Params:
            params = request parameters
            node_conn_pool = node connection pool to assign request to

    ***************************************************************************/

    protected void assignToNode_ ( IRequestParams params,
        NodeConnectionPool node_conn_pool )
    {
        node_conn_pool.assign(params);
    }


    /***************************************************************************

        Returns:
            the number of nodes in the registry

    ***************************************************************************/

    public size_t length ( )
    {
        return this.nodes.list.length;
    }


    /***************************************************************************

        Returns:
            the maximum number of connections per node ("conn_limit"
            constructor parameter).

    ***************************************************************************/

    public size_t max_connections_per_node ( )
    {
        return this.settings.conn_limit;
    }


    /***************************************************************************

        Returns:
            size (in bytes) of per-node queue of pending requests ("queue_limit"
            constructor parameter)

    ***************************************************************************/

    public size_t queue_limit ( )
    {
        return this.settings.queue_size;
    }


    /***************************************************************************

        Returns:
            the number of requests in the all the per node request queues

    ***************************************************************************/

    public size_t queued_requests ( )
    {
        size_t length = 0;
        foreach ( connpool; this.nodes.list )
        {
            length += connpool.queued_requests;
        }
        return length;
    }


    /***************************************************************************

        Returns:
            the number of requests in all the per node overflow queues

    ***************************************************************************/

    public size_t overflowed_requests ( )
    {
        size_t length = 0;
        foreach ( connpool; this.nodes.list )
        {
            length += connpool.overflowed_requests;
        }
        return length;
    }


    /***************************************************************************

        'foreach' iteration over the node connection pools in the order
        specified by this.nodes.list.

    ***************************************************************************/

    protected int opApply ( int delegate ( ref INodeConnectionPool connpool ) dg )
    {
        int result = 0;

        foreach ( connpool; this.nodes.list )
        {
            INodeConnectionPool iconnpool = connpool;

            result = dg(iconnpool);

            if (result) break;
        }

        return result;
    }


    /***************************************************************************

        INodeRegistryInfo method. 'foreach' iteration over information
        interfaces to the node connection pools.

    ***************************************************************************/

    public int opApply ( int delegate ( ref INodeConnectionPoolInfo ) dg )
    {
        int result = 0;

        foreach ( connpool; this.nodes.list )
        {
            INodeConnectionPoolInfo iconnpool = connpool;

            result = dg(iconnpool);

            if (result) break;
        }

        return result;
    }


    /***************************************************************************

        Determines whether the given request params describe a request which
        should be sent to all nodes simultaneously.

        Params:
            params = request parameters

        Returns:
            true if the request should be added to all nodes

    ***************************************************************************/

    abstract public bool allNodesRequest ( IRequestParams params );


    /***************************************************************************

        Gets the connection pool which is responsible for the given request.

        Params:
            params = request parameters

        Returns:
            connection pool responsible for request (null if none found)

    ***************************************************************************/

    abstract protected NodeConnectionPool getResponsiblePool (
        IRequestParams params );


    /***************************************************************************

        Gets a ClientCommandParams struct describing a client-only command from
        a request params struct.

        Params:
            params = request parameters

        Returns:
            ClientCommandParams struct extracted from request parameters

    ***************************************************************************/

    private ClientCommandParams getClientCommandParams ( IRequestParams params )
    {
        ClientCommandParams client_params;
        client_params.nodeitem = params.node;
        client_params.command = params.client_command;
        return client_params;
    }


    /***************************************************************************

        Creates a new instance of the node request pool class.

        Params:
            address = node address
            port = node service port

        Returns:
            new NodeConnectionPool instance

    ***************************************************************************/

    abstract protected NodeConnectionPool newConnectionPool ( mstring address,
        ushort port );


    /***************************************************************************

        Checks whether the given address and port correspond to a node which is
        already in the registry.

        Params:
            address = node address
            port = node service port

        Returns:
            pointer to the node's connection pool, if it's already in the
            registry, null otherwise.

    ***************************************************************************/

    protected NodeConnectionPool* inRegistry ( mstring address, ushort port )
    {
        auto node = NodeItem(address, port);
        return node in this.nodes.map;
    }


    /***************************************************************************

        Handles a client-only command which has been assigned. Client-only
        commands do not need to be placed in a request queue, as they can be
        executed immediately.

        Params:
            client_params = paramaters describing a client-only command

        Returns:
            true if the command was handled, false otherwise. (This behaviour
            allows sub-classes to override, call this method, then handle any
            cases not covered here.)

    ***************************************************************************/

    protected bool assignClientCommand ( ClientCommandParams client_params )
    {
        NodeConnectionPool conn_pool ( )
        {
            auto conn_pool = client_params.nodeitem in this.nodes.map;
            enforce(this.no_node_exception, conn_pool);

            return *conn_pool;
        }

        with ( ClientCommandParams.Command ) switch ( client_params.command )
        {
            case SuspendNode:
                conn_pool.suspend();
                return true;

            case ResumeNode:
                conn_pool.resume();
                return true;

            case Disconnect:
                foreach ( connpool; this.nodes.list )
                {
                    connpool.closeConnections();
                }
                return true;

            case DisconnectNodeIdleConns:
                conn_pool.closeIdleConnections();
                return true;

            case Flush:
                this.flushables.flush();
                return true;

            default:
                return false;
        }
    }
}
