/*******************************************************************************

    Asynchronous/event-driven client using non-blocking socket I/O (epoll)

    Client base class with the following features:
        * A registry of distributed server nodes which can be added to (with the
          addNodes() method), and iterated over.
        * A means of assigning requests to the client via the protected
          assignParams() method. The bulk of the work of request assignment is
          done by the node registry (see
          swarm.client.connection.NodeRegistry).
        * Validation of request parameters before assignment to the registry
          (the base class performs a simple validation, but further checks can
          be added via the protected validateRequestParams_() method).

    copyright:      Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.model.IClient;



/*******************************************************************************

    Imports

*******************************************************************************/

import swarm.Const;

import swarm.client.ClientExceptions;
import swarm.client.RequestSetup;
import swarm.client.ClientCommandParams;

import swarm.client.helper.NodesConfigReader;

import swarm.client.request.params.IRequestParams;

import swarm.client.request.context.RequestContext;

import swarm.client.request.notifier.IRequestNotification;

import swarm.client.registry.model.INodeRegistry;
import swarm.client.registry.model.INodeRegistryInfo;

import swarm.client.connection.model.INodeConnectionPoolErrorReporter;

import swarm.client.connection.RequestOverflow;

import ocean.core.Enforce;

import ocean.io.select.EpollSelectDispatcher;

import ocean.util.config.ConfigFiller;

import ocean.transition;

/*******************************************************************************

    IClient

*******************************************************************************/

public abstract class IClient
{
    /***************************************************************************

        Configuration base class for swarm clients. Designed to be read from an
        application's config.ini file via ocean.util.config.ClassFiller.

    ***************************************************************************/

    static class Config
    {
        /***********************************************************************

            Location of the nodes configuration file, has to be specified

        ***********************************************************************/

        istring nodes_file;

        /***********************************************************************

            Limit of parallel connections per node, at least one connection is
            required

        ***********************************************************************/

        Min!(size_t, 1) connection_limit;

        /***********************************************************************

            Size in bytes of the request queue per node

        ***********************************************************************/

        Min!(size_t, 1024) queue_size;

        /***********************************************************************

            Default values

        ***********************************************************************/

        public const default_connection_limit = 5;
        public const default_queue_size = 32 * 1024;

        /***********************************************************************

            Constructor, to set default values

        ***********************************************************************/

        this ( )
        {
            // Trying to use opAssign via natural `a = b` syntax results in
            // Error: function ocean.util.config.ClassFiller.Min!(ulong, 1LU, 0LU).Min.WrapperStructCore!(ulong, 0LU).opCall () is not callable using argument types (int)
            // because dmd2 thinks you try to do parens-less "setter" call instead
            this.connection_limit.opAssign(default_connection_limit);
            this.queue_size.opAssign(default_queue_size);
        }
    }


    /***************************************************************************

        Local alias definitions

    ***************************************************************************/

    public alias .RequestContext RequestContext;

    public alias .EpollSelectDispatcher EpollSelectDispatcher;

    public alias .IRequestParams IRequestParams;

    protected alias .INodeConnectionPoolErrorReporter INodeConnectionPoolErrorReporter;


    /***************************************************************************

        Default fiber stack size. 16K on 64-bit architecture.

    ***************************************************************************/

    public const size_t default_fiber_stack_size = size_t.sizeof * 2 * 1024;


    /***************************************************************************

        Returns:
            generic node registry info

    ***************************************************************************/

    protected INodeRegistryInfo nodes_;


    /***************************************************************************

        String buffer which can be used for formatting of notification messages.

    ***************************************************************************/

    public mstring msg_buf;


    /***************************************************************************

        Epoll selector used by the client. Passed as a reference in the
        constructor. Stored locally so that it can be passed to the scheduler,
        if request scheduling is enabled.

    ***************************************************************************/

    protected EpollSelectDispatcher epoll;


    /***************************************************************************

        Generic node registry

    ***************************************************************************/

    protected INodeRegistry registry;


    /***************************************************************************

        Exceptions thrown in error cases.

    ***************************************************************************/

    private NoTimeoutsException no_timeouts_exception;


    /***************************************************************************

        Constructor

        Params:
            epoll = select dispatcher to use for assigning requests
            registry = used node connections registry

    ***************************************************************************/

    protected this ( EpollSelectDispatcher epoll, INodeRegistry registry )
    {
        assert(epoll !is null, typeof(this).stringof ~ ".this: reference to epoll select dispatcher is null");
        assert(registry !is null, typeof(this).stringof ~ ".this: reference to registry is null");

        this.epoll = epoll;
        this.nodes_ = this.registry = registry;

        this.no_timeouts_exception = new NoTimeoutsException;
    }


    /***************************************************************************

        Adds a node connection to the registry.

        Params:
            address = node address
            port = node service port

        Throws:
            exception if the node already exists in the registry

    ***************************************************************************/

    public void addNode ( mstring host, ushort port )
    {
        this.registry.add(host, port);
    }


    /***************************************************************************

        Adds node connections to the registry, read from a config file. The
        nodes are specified in the config file as follows:

        ---
            192.168.2.128:30010
            192.168.2.128:30011
        ---

        Params:
            file = name of config file to read

        Returns:
            this instance

        Throws:
            exception if the node already exists in the registry

    ***************************************************************************/

    public typeof (this) addNodes ( cstring file )
    {
        foreach ( node; NodesConfigReader(file) )
        {
            this.registry.add(node.Address, node.Port);
        }

        return this;
    }


    /***************************************************************************

        Returns:
            Public generic nodes info

    ***************************************************************************/

    public INodeRegistryInfo nodes ()
    {
        return this.nodes_;
    }


    /***************************************************************************

        Reads configuration info from a plain text nodes config file (formatted
        as specified above in addNodes()), and returns the number of nodes
        defined in it.

        Params:
            file = file name of nodes config file to read node address / ports
                from

        Returns:
            the number of nodes defined in the specified nodes config file

    ***************************************************************************/

    static public size_t nodesInConfigFile ( istring file )
    {
        auto nodes = NodesConfigReader(file);
        return nodes.length;
    }


    /***************************************************************************

        Creates a SuspendNode client-command, which causes the client to stop
        processing further requests to the specified node. Request
        processing for the node can be restarted by assigning a ResumeNode
        client-command (see resume(), below).

        Note that any requests to the specified node which are already being
        processed are not affected.

        Params:
            nodeitem = address & port of node to stop processing requests for
            notifier = notification callback

        Returns:
            instance allowing optional settings to be set and then to be passed
            to assign()

    ***************************************************************************/

    private struct SuspendNode
    {
        mixin ClientCommandBase;
        mixin Node;

        mixin RequestParamsSetup; // private setup() method, used by assign()
    }

    public SuspendNode suspend ( NodeItem nodeitem,
        IRequestNotification.Callback notifier )
    {
        return *SuspendNode(ClientCommandParams.Command.SuspendNode, notifier)
            .node(nodeitem);
    }


    /***************************************************************************

        Creates a ResumeNode client-command, which causes the client to resume
        processing requests to the specified node after having been
        previously suspended by a SuspendNode client-command.

        Params:
            nodeitem = address & port of node to resume processing requests for
            notifier = notification callback

        Returns:
            instance allowing optional settings to be set and then to be passed
            to assign()

    ***************************************************************************/

    private struct ResumeNode
    {
        mixin ClientCommandBase;
        mixin Node;

        mixin RequestParamsSetup; // private setup() method, used by assign()
    }

    public ResumeNode resume ( NodeItem nodeitem,
        IRequestNotification.Callback notifier )
    {
        return *ResumeNode(ClientCommandParams.Command.ResumeNode, notifier)
            .node(nodeitem);
    }


    /***************************************************************************

        Creates a DisconnectNode client-command, which causes the client to
        disconnect all idle connections to the specified node.

        Params:
            nodeitem = address & port of node to disconnect connections to
            notifier = notification callback

        Returns:
            instance allowing optional settings to be set and then to be passed
            to assign()

    ***************************************************************************/

    private struct DisconnectIdle
    {
        mixin ClientCommandBase;
        mixin Node;

        mixin RequestParamsSetup; // private setup() method, used by assign()
    }

    public DisconnectIdle disconnectIdle ( NodeItem nodeitem,
        IRequestNotification.Callback notifier )
    {
        return *DisconnectIdle(
            ClientCommandParams.Command.DisconnectNodeIdleConns, notifier)
            .node(nodeitem);
    }


    /***************************************************************************

        Creates a Disconnect client-command, which causes the client to
        disconnect all connections to all nodes.

        Params:
            notifier = notification callback

        Returns:
            instance allowing optional settings to be set and then to be passed
            to assign()

    ***************************************************************************/

    private struct Disconnect
    {
        mixin ClientCommandBase;

        mixin RequestParamsSetup; // private setup() method, used by assign()
    }

    public Disconnect disconnect ( IRequestNotification.Callback notifier )
    {
        return Disconnect(ClientCommandParams.Command.Disconnect, notifier);
    }


    /***************************************************************************

        Creates a DisableNode client-command, which causes the client to
        temporarily remove a node from its registry, pending execution of an
        EnableNode client-command to reinstate the node.

        Note that this command only works with clients using a registry which
        implements IFluidNodeRegistry.

        Params:
            nodeitem = address & port of node to disable
            notifier = notification callback

        Returns:
            instance allowing optional settings to be set and then to be passed
            to assign()

    ***************************************************************************/

    private struct DisableNode
    {
        mixin ClientCommandBase;
        mixin Node;

        mixin RequestParamsSetup; // private setup() method, used by assign()
    }

    public DisableNode disableNode ( NodeItem nodeitem,
        IRequestNotification.Callback notifier )
    {
        return *DisableNode(
            ClientCommandParams.Command.DisableNode, notifier)
            .node(nodeitem);
    }


    /***************************************************************************

        Creates an EnableNode client-command, which causes the client to
        reinstate a node into its registry, which was previously removed by a
        DisableNode client-command.

        Note that this command only works with clients using a registry which
        implements IFluidNodeRegistry.

        Params:
            nodeitem = address & port of node to enable
            notifier = notification callback

        Returns:
            instance allowing optional settings to be set and then to be passed
            to assign()

    ***************************************************************************/

    private struct EnableNode
    {
        mixin ClientCommandBase;
        mixin Node;

        mixin RequestParamsSetup; // private setup() method, used by assign()
    }

    public EnableNode enableNode ( NodeItem nodeitem,
        IRequestNotification.Callback notifier )
    {
        return *EnableNode(
            ClientCommandParams.Command.EnableNode, notifier)
            .node(nodeitem);
    }


    /***************************************************************************

        Returns:
            interface to the request queue overflow handler for this client

    ***************************************************************************/

    protected IRequestOverflow requestOverflow ( )
    {
        return new VoidOverflow;
    }


    /***************************************************************************

        Returns:
            interface to the error reporter for this client

        Note that the error reporter interface is a completely separate system
        to the request notifier which provides feedback to the user. The error
        reporter is used purely internally to the client, to enable client
        extensions a notification hook to error and timeout events.

    ***************************************************************************/

    protected INodeConnectionPoolErrorReporter errorReporter ( )
    {
        return null;
    }


    /***************************************************************************

        Assigns a new request to the client. The request is validated, and if
        valid, the request is sent to the node registry, where it will be either
        executed immediately (if a free connection is available) or queued for
        later execution.

        The abstract validateRequestParams() method is expected to throw an
        exception if the request should not be assigned. In this case the
        exception is caught and passed to the abstract assignParamsFailed()
        method.

        Params:
            request = request to assign

    ***************************************************************************/

    protected void assignParams ( IRequestParams params )
    {
        try
        {
            this.validateRequestParams(params);

            this.registry.assign(params, &this.assignParamsFailed);
        }
        catch ( Exception e )
        {
            this.assignParamsFailed(params, e);
        }
    }


    /***************************************************************************

        Creates a new request params instance (derived from IRequestParams), and
        passes it to the provided delegate. In this way, scoped IRequestParams
        instances can be created and used abstractly via this class.

        This method is used by the request scheduler plugin, which needs to be
        able to construct and use a request params instance without knowing
        which derived type is used by the client.

        Params:
            dg = delegate to receive and use created scope IRequestParams
                instance

    ***************************************************************************/

    abstract protected void scopeRequestParams (
        void delegate ( IRequestParams params ) dg );


    /***************************************************************************

        Checks whether the given request params are valid. The method should
        throw an exception (which will be caught in assignParams(), above) to
        indicate any errors.

        Params:
            params = request params to check

        Throws:
            * if a timeout was requested but the epoll selector doesn't support
              timeouts

    ***************************************************************************/

    private void validateRequestParams ( IRequestParams params )
    {
        if ( params.timeout_ms )
        {
            enforce(this.no_timeouts_exception, this.epoll.timeout_enabled);
        }

        this.validateRequestParams_(params);
    }

    protected void validateRequestParams_ ( IRequestParams params )
    {
    }


    /***************************************************************************

        Called when an exception is caught while performing assignParams().

        Params:
            params = request params being assigned
            e = exception which occurred

    ***************************************************************************/

    protected void assignParamsFailed ( IRequestParams params, Exception e )
    {
        params.notify(null, 0, e, IStatusCodes.E.Undefined,
            IRequestNotification.Type.Finished);
    }
}
