/*******************************************************************************

    Base class for asynchronously/selector managed fiber-based requests

    Provides the very basic facilities of a fiber-based request handler:
        * A FiberSelectWriter and FiberSelectReader for asynchronous reading and
          writing.
        * error() and reset() methods for notification of request states.

    copyright:      Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.common.request.model.IFiberRequest;



/*******************************************************************************

    Imports

*******************************************************************************/

import swarm.protocol.FiberSelectReader;
import swarm.protocol.FiberSelectWriter;



/*******************************************************************************

    Fiber-based request handler base class template. Shared between node &
    client.

    Template params:
        Params = type containing the information required to initiate a new
            request.

*******************************************************************************/

public abstract scope class IFiberRequest
{
    /***************************************************************************

        Local alias type redefinitions

    ***************************************************************************/

    protected alias .FiberSelectReader FiberSelectReader;

    protected alias .FiberSelectWriter FiberSelectWriter;


    /***************************************************************************

        FiberSelectReader/SelectWriter references, passed into constructor

    ***************************************************************************/

    protected FiberSelectReader reader;

    protected FiberSelectWriter writer;


    /***************************************************************************

        Constructor.

        Params:
            reader = FiberSelectReader instance to use for read requests
            writer = FiberSelectWriter instance to use for write requests

    ***************************************************************************/

    protected this ( FiberSelectReader reader, FiberSelectWriter writer )
    {
        this.reader = reader;
        this.writer = writer;
    }
}
