/*******************************************************************************

    Request handler class initialisation boilerplate.

    Copyright:
        Copyright (c) 2018 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module integrationtest.neo.node.request.mixins.RequestCore;

template RequestCore ( )
{
    import swarm.neo.node.RequestOnConn;
    import integrationtest.neo.node.Storage;

    /// Request-on-conn of this request handler.
    private RequestOnConn connection;

    /// Storage.
    private Storage storage;

    /***************************************************************************

        Passes the request-on-conn and request resource acquirer to the handler.

        Params:
            connection = request-on-conn in which the request handler is called
            resources = request resources acquirer

    ***************************************************************************/

    public void initialise ( RequestOnConn connection, Object resources )
    {
        this.connection = connection;
        this.storage = cast(Storage)resources;
        assert(this.storage !is null);
    }
}
