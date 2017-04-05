/*******************************************************************************

    Structure holding the user-specified context for a client request. The
    specified request context is passed back to the calling code when the i/o
    delegate is called.

    copyright:      Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.request.context.RequestContext;



/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.core.ContextUnion;



/*******************************************************************************

    Request context.

*******************************************************************************/

public alias ContextUnion RequestContext;

