/*******************************************************************************

    Abstract base class for various swarm node request protocols.

    copyright: Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.node.protocol.Command;

/*******************************************************************************

    Imports

*******************************************************************************/

import swarm.node.request.model.IRequest;

import ocean.text.convert.Format;

import ocean.transition;

/*******************************************************************************

    Any swarm node request protocol base class

*******************************************************************************/

public abstract scope class Command : IRequest
{
    /***************************************************************************

        Name of command.

    ***************************************************************************/

    private cstring name;

    /***************************************************************************

        Constructor

        Params:
            name = command code string
            reader = FiberSelectReader instance to use for read requests
            writer = FiberSelectWriter instance to use for write requests

    ***************************************************************************/

    public this ( cstring name, FiberSelectReader reader,
        FiberSelectWriter writer )
    {
        super(reader, writer);
        this.name = name;
    }

    /***************************************************************************

        Returns:
            name of this command (provided by derivatives via constructor)

    ***************************************************************************/

    public cstring command_name ( )
    {
        return this.name;
    }

    /***************************************************************************

        Formats a description of this command into the provided buffer. The
        default implementation simply formats the name of the command. Derived
        request classes may override and add more detailed information.

        Params:
            dst = buffer to format description into

        Returns:
            description of command (slice of dst)

    ***************************************************************************/

    override public mstring description ( ref mstring dst )
    {
        dst.length = 0;
        enableStomping(dst);
        Format.format(dst, "{} request", this.name);
        return dst;
    }

    /***************************************************************************

        Ensure that finalize method gets run in the very end of any request

    ***************************************************************************/

    final override protected void handle_ ( )
    {
        scope(exit)
            this.finalizeRequest();

        this.handleRequest();
    }

    /***************************************************************************

        Reads any data from the client which is required for the request. Does
        not do any actual processing of the data. Each specific command class
        implements it in its own way

    ***************************************************************************/

    override abstract protected void readRequestData ( );

    /***************************************************************************

        Actual request handling method (runs after readRequestData). To be
        implemented by derivatives

    ***************************************************************************/

    abstract protected void handleRequest ( );

    /***************************************************************************

        Method that is guaranteed to run upon request termination - both
        expected and via exceptions. Does nothing by default, override as
        appropriate for specific request implementation.

    ***************************************************************************/

    protected void finalizeRequest ( ) { }
}
