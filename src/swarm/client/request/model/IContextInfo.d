/*******************************************************************************

    An interface to get the context associated with a request

    copyright:      Copyright (c) 2013-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.request.model.IContextInfo;

import swarm.client.request.context.RequestContext;


/*******************************************************************************

    An interface to get the context associated with a request

*******************************************************************************/

public interface IContextInfo
{
    /***************************************************************************

        Returns:
            the context set for this request

    ***************************************************************************/

    public RequestContext context ( );
}
