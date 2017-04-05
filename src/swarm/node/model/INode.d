/*******************************************************************************

    Interface for node implementation

    copyright:      Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.node.model.INode;



/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.io.select.EpollSelectDispatcher;



/*******************************************************************************

    Node interface

*******************************************************************************/

public interface INode
{
    /***************************************************************************

        Registers any selectables in the node (including the listener) with the
        provided epoll selector.

        Params:
            epoll = epoll selector to register with

    ***************************************************************************/

    public void register ( EpollSelectDispatcher epoll );


    /***************************************************************************

        Flushes write buffers of stream connections.

    ***************************************************************************/

    public void flush ( );


    /***************************************************************************

        Stops the node from handling any more requests and shuts down all active
        connections.

        Params:
            epoll = epoll selector to unregister select listener from

    ***************************************************************************/

    public void stopListener ( EpollSelectDispatcher epoll );


    /***************************************************************************

        Performs any required shutdown behaviour for the node.

    ***************************************************************************/

    public void shutdown ();


    /***************************************************************************

        Writes connection information to log file.

    ***************************************************************************/

    public void connectionLog ( );
}

