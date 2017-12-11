/*******************************************************************************

    Common protocol definitions for the Put request.

    Copyright:
        Copyright (c) 2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module test.neo.common.Put;

import swarm.neo.request.Command;

/*******************************************************************************

    Status code enum. Sent from the node to the client.

*******************************************************************************/

public enum RequestStatusCode : StatusCode
{
    None,       // Invalid, default value

    Succeeded,  // Value written
    Error       // Internal node error occurred
}
