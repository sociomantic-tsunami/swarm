/*******************************************************************************

    Information about a connection pool (set of connections to a single node)

    copyright:      Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.connection.model.INodeConnectionPoolInfo;


/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.transition;


/******************************************************************************/

public interface INodeConnectionPoolInfo
{
    /***************************************************************************

        Returns:
            the address of the node

    ***************************************************************************/

    mstring address ( );


    /***************************************************************************

        Returns:
            the service port of the node

    ***************************************************************************/

    ushort port ( );


    /**************************************************************************

        Returns the total number of node connections in the pool, that is, the
        maximum number of connections to this node that have ever been busy
        simultaneously.

        Returns:
            the total number of connections in the pool.

     **************************************************************************/

    size_t length ( );


    /**************************************************************************

        Returns the number of idle node connections. The socket connection of
        each of these connections may or may not be open currently.

        Returns:
            the number of idle node connections.

     **************************************************************************/

    size_t num_idle ( );


    /**************************************************************************

        Returns the number of busy node connections.

        Returns:
            the number of busy items in pool

     **************************************************************************/

    size_t num_busy ( );


    /**************************************************************************

        Returns:
            the number of connections currently being established

        TODO

     **************************************************************************/

//    uint num_connecting ( );


    /***************************************************************************

        Returns:
            the number of requests in the request queue

    ***************************************************************************/

    size_t queued_requests ( );


    /***************************************************************************

        Returns:
            the number of bytes occupied in the request queue

    ***************************************************************************/

    size_t queued_bytes ( );


    /***************************************************************************

        Returns:
            the number of requests in the overflow queue

    ***************************************************************************/

    size_t overflowed_requests ( );


    /**************************************************************************

        Returns:
            the number of requests which ended due to an error, since the last
            call to resetCounters()

     **************************************************************************/

    ulong error_count ( );


    /**************************************************************************

        Returns:
            the number of requests which ended due to an I/O timeout, since the
            last call to resetCounters()

     **************************************************************************/

    ulong io_timeout_count ( );


    /**************************************************************************

        Returns:
            the number of requests which ended due to a connection timeout,
            since the last call to resetCounters()

     **************************************************************************/

    ulong conn_timeout_count ( );


    /**************************************************************************

        Resets the internal counters of errors and timeouts.

     **************************************************************************/

    void resetCounters ( );


    /**************************************************************************

        Returns:
            whether the request queue for this connection pool is currently
            suspended (via the SuspendNode client command)

     **************************************************************************/

    bool suspended ( );
}
