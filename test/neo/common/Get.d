/*******************************************************************************

    Common protocol definitions for the Get request.

    Copyright:
        Copyright (c) 2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module test.neo.common.Get;

import swarm.neo.request.Command;

/*******************************************************************************

    Status code enum. Sent from the node to the client.

*******************************************************************************/

public enum RequestStatusCode : StatusCode
{
    None,   // Invalid, default value

    Value,  // Value fetched
    Empty,  // Record empty
    Error   // Internal node error occurred
}
