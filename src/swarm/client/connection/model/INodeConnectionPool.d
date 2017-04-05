/*******************************************************************************

    Control interface to a node connection pool.

    copyright:      Copyright (c) 2013-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.connection.model.INodeConnectionPool;



/*******************************************************************************

    Imports

*******************************************************************************/

import swarm.client.connection.model.INodeConnectionPoolInfo;

import swarm.client.connection.RequestConnection;

import swarm.client.request.params.IRequestParams;



public interface INodeConnectionPool : INodeConnectionPoolInfo
{
    /***************************************************************************

        Called when a connection has finished handling a request. If there are
        requests in the queue, the next request is popped and assigned to the
        connection that has just become idle. Otherwise the connection will be
        unregistered from the select dispatcher.

        Params:
            params = outputs request params for next request

        Returns:
            true if another request is available

    ***************************************************************************/

    bool nextRequest ( IRequestParams params );


    /***************************************************************************

        Puts a connection back into the pool.

        Params:
            connection = IRequestConnection instance to recycle

    ***************************************************************************/

    void recycleConnection ( IRequestConnection instance );


    /***************************************************************************

        Increments the error counter.

    ***************************************************************************/

    void had_error ( );


    /***************************************************************************

        Increments the I/O timeout counter.

    ***************************************************************************/

    void had_io_timeout ( );


    /***************************************************************************

        Increments the connection timeout counter.

    ***************************************************************************/

    void had_conn_timeout ( );
}

