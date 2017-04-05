/*******************************************************************************

    Version:        2014-01-13: Initial release

    Authors:        Gavin Norman

    Interface to a per-node error/timeout reporter.

    Copyright:      Copyright (c) 2014-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.connection.model.INodeConnectionPoolErrorReporter;


/*******************************************************************************

    Imports

*******************************************************************************/

import swarm.Const : NodeItem;



/*******************************************************************************

    Interface to a per-node error/timeout reporter.

*******************************************************************************/

public interface INodeConnectionPoolErrorReporter
{
    /***************************************************************************

        Convenience alias to avoid repeated import

    ***************************************************************************/

    alias .NodeItem NodeItem;


    /***************************************************************************

        Called when an error occurred.

        Params:
            node = address/port of node responsible for request

    ***************************************************************************/

    void had_error ( NodeItem node );


    /***************************************************************************

        Called when an I/O timeout occurred.

        Params:
            node = address/port of node responsible for request

    ***************************************************************************/

    void had_io_timeout ( NodeItem node );


    /***************************************************************************

        Called when a connection timeout occurred.

        Params:
            node = address/port of node responsible for request

    ***************************************************************************/

    void had_conn_timeout ( NodeItem node );
}

