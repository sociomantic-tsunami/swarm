/*******************************************************************************

    Settings related to establishing and managing connections to the nodes.
    These are wrapped in a struct for convenient storage and passing between
    functions.

    Copyright:      Copyright (c) 2014-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.model.ClientSettings;



public struct ClientSettings
{
    /***************************************************************************

        The maximum number of connections which will be opened to each node

    ***************************************************************************/

    public size_t conn_limit;


    /***************************************************************************

        The size of the request queue to each node (in bytes)

    ***************************************************************************/

    public size_t queue_size;


    /***************************************************************************

        The size (in bytes) of the stack of each connection's fiber

    ***************************************************************************/

    public size_t fiber_stack_size;


    /***************************************************************************

        Invariant: checks that none of the above values are 0. The invariant can
        be called as follows:
        ---
            ClientSettings s;
            assert(&s);
        ---

    ***************************************************************************/

    invariant ()
    {
        assert(this.conn_limit > 0);
        assert(this.queue_size > 0);
        assert(this.fiber_stack_size > 0);
    }
}
