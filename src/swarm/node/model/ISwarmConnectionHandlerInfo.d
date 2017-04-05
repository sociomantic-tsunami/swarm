/*******************************************************************************

    Version:        2013-07-19: Initial release

    Authors:        Gavin Norman

    Informational (i.e. non-destructive) interface to a swarm connection
    handler. Adds swarm-specific extensions to the IConnectionHandlerInfo from
    ocean.

    Copyright:      Copyright (c) 2013-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.node.model.ISwarmConnectionHandlerInfo;



/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.transition;

import ocean.net.server.connection.IConnectionHandlerInfo;
import ocean.io.select.client.model.ISelectClientInfo;

import swarm.Const;



public interface ISwarmConnectionHandlerInfo : IConnectionHandlerInfo
{
    /***************************************************************************

        Convenience aliases for implementing classes

    ***************************************************************************/

    alias .ISelectClientInfo ISelectClientInfo;

    alias .IConnectionHandlerInfo IConnectionHandlerInfo;


    /***************************************************************************

        Returns:
            true if the connection has had an I/O event since the last time this
            method was called

    ***************************************************************************/

    bool had_io ( );


    /***************************************************************************

        Returns:
            the code of the command currently being handled

    ***************************************************************************/

    ICommandCodes.Value command ( );


    /***************************************************************************

        Returns:
            informational interface to currently registered ISelectClient for
            this connection (may be null if no client is registered)

    ***************************************************************************/

    ISelectClientInfo registered_client ( );

    /***************************************************************************

        Obtains the IP address most recently passed to bind() or connect() or
        obtained by accept().

        Returns:
            the current IP address.

    ***************************************************************************/

    cstring address ( );

    /***************************************************************************

        Obtains the port number most recently passed to bind() or connect() or
        obtained by accept().

        Returns:
            the current port number.

    ***************************************************************************/

    ushort port ( );
}
