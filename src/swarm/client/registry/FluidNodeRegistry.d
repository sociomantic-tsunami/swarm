/*******************************************************************************

    Version:        2014-01-21: Initial release

    Authors:        Gavin Norman

    Flexible node registry with methods to remove, disable and re-enable nodes.
    Can be used by clients for distributed systems where the set of nodes is
    either fluid, or where each node is essentially identical -- allowing
    requests to be routed flexibly.

    Copyright:      Copyright (c) 2014-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.registry.FluidNodeRegistry;



/*******************************************************************************

    Imports

*******************************************************************************/

import swarm.client.registry.model.IFluidNodeRegistry;

import swarm.client.connection.model.INodeConnectionPoolInfo;

import swarm.client.registry.NodeRegistry;

import swarm.client.registry.DisablableNodeSet;

import swarm.Const : NodeItem;

debug ( SwarmClient ) import ocean.io.Stdout;

import ocean.transition;


public class FluidNodeRegistry : NodeRegistry, IFluidNodeRegistry
{
    /***************************************************************************

        Alias for sub-classes.

    ***************************************************************************/

    protected alias .DisablableNodeSet DisablableNodeSet;


    /***************************************************************************

        Constructor

        Params:
            epoll = selector dispatcher instance to register the socket and I/O
                events
            settings = client settings instance
            request_overflow = overflow handler for requests which don't fit in
                the request queue
            nodes = DisablableNodeSet-derived class to manage the set of
                registered nodes
            error_reporter = error reporter instance to notify on error or
                timeout

    ***************************************************************************/

    public this ( EpollSelectDispatcher epoll, ClientSettings settings,
        IRequestOverflow request_overflow, DisablableNodeSet nodes,
        INodeConnectionPoolErrorReporter error_reporter )
    {
        super(epoll, settings, request_overflow, nodes, error_reporter);
    }


    /***************************************************************************

        Removes a node connection from the registry. The node's connection pool
        is discarded and cannot be retrieved. Re-adding the node with add() will
        create a new connection pool. (i.e. this is intended to be a final
        removal. If you want to temporarily remove a node, consider using
        disable(), below.)

        Params:
            address = node address
            port = node service port

        Throws:
            exception if the node does not exist in the registry

    ***************************************************************************/

    override public void remove ( mstring address, ushort port )
    out
    {
        assert(!this.inRegistry(address, port), "node in registry after remove()");
    }
    body
    {
        this.nodes.remove(NodeItem(address, port));
    }


    /***************************************************************************

        Disables a node connection in the registry. The disabled node is added
        to the internal list of disabled nodes, ready to be reinstated when
        requested.

        Params:
            address = node address
            port = node service port

        Throws:
            exception if the node does not exist in the registry

    ***************************************************************************/

    override public void disable ( mstring address, ushort port )
    out
    {
        assert(!this.inRegistry(address, port), "node in registry after disable()");
    }
    body
    {
        debug ( SwarmClient ) Stderr.formatln("Disabling {}:{}", address, port);

        auto disablable_nodes = cast(DisablableNodeSet)this.nodes;
        disablable_nodes.disable(NodeItem(address, port));
    }


    /***************************************************************************

        Enables a node connection in the registry. The node is found in the list
        of disabled nodes and is reinstated in the registry.

        Params:
            address = node address
            port = node service port

        Throws:
            exception if the node does not exist in the list of disabled nodes

    ***************************************************************************/

    override public void enable ( mstring address, ushort port )
    out
    {
        assert(this.inRegistry(address, port), "node not in registry after enable()");
    }
    body
    {
        debug ( SwarmClient ) Stderr.formatln("Enabling {}:{}", address, port);

        auto disablable_nodes = cast(DisablableNodeSet)this.nodes;
        disablable_nodes.enable(NodeItem(address, port));
    }


    /***************************************************************************

        Returns:
            the number of nodes which have been disabled

    ***************************************************************************/

    override public size_t num_disabled ( )
    {
        auto disablable_nodes = cast(DisablableNodeSet)this.nodes;
        return disablable_nodes.num_disabled;
    }


    /***************************************************************************

        Returns:
            the fraction of nodes which have been disabled

    ***************************************************************************/

    override public float disabled_fraction ( )
    {
        auto disablable_nodes = cast(DisablableNodeSet)this.nodes;
        auto disabled = disablable_nodes.num_disabled;
        auto total = disabled + this.nodes.list.length;
        return cast(float)disabled / cast(float)total;
    }


    /***************************************************************************

        Iterator over the set of disabled nodes.

    ***************************************************************************/

    private scope class DisabledIterator : IDisabledIterator
    {
        /***********************************************************************

            opApply iterator over the address/port of disabled nodes and the
            informational interface to the associated pool of connections.

        ***********************************************************************/

        public override int opApply ( int delegate ( ref NodeItem,
            ref INodeConnectionPoolInfo ) dg )
        {
            auto disablable_nodes = cast(DisablableNodeSet)this.outer.nodes;

            int res;
            foreach ( node_item, conn_pool; disablable_nodes )
            {
                auto conn_pool_info = cast(INodeConnectionPoolInfo)conn_pool;
                res = dg(node_item, conn_pool_info);
                if ( res ) break;
            }
            return res;
        }
    }


    /***************************************************************************

        Gets an iterator over the set of disabled nodes. The iterator is newed
        at scope (on the stack) and passed to the provided delegate.

        Params:
            dg = delegate to which iterator will be passed

    ***************************************************************************/

    override public void disabled_nodes ( void delegate ( IDisabledIterator ) dg )
    {
        scope it = new DisabledIterator;
        dg(it);
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

    override protected bool assignClientCommand ( ClientCommandParams client_params )
    {
        auto handled = super.assignClientCommand(client_params);
        if ( handled ) return true;

        with ( ClientCommandParams.Command ) switch ( client_params.command )
        {
            case DisableNode:
                this.disable(client_params.nodeitem.Address,
                    client_params.nodeitem.Port);
                return true;

            case EnableNode:
                this.enable(client_params.nodeitem.Address,
                    client_params.nodeitem.Port);
                return true;

            default:
                return false;
        }
    }
}
