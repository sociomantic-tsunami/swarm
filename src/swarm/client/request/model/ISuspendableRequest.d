/*******************************************************************************

    Interface for a request which can be suspended and resumed.

    copyright:      Copyright (c) 2015-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.request.model.ISuspendableRequest;

import swarm.client.request.model.INodeInfo;
import swarm.client.request.model.IContextInfo;

import ocean.io.model.ISuspendable;

/*******************************************************************************

    Interface to a request which can:
        * Be suspended and resumed.
        * Return the associated context which was provided by the user when the
          request was started.
        * Provide the address and port of the node which is handling the request.

*******************************************************************************/

public interface ISuspendableRequest : ISuspendable, IContextInfo, INodeInfo
{
}
