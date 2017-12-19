/*******************************************************************************

    Common protocol definitions for the DoublePut request.

    Copyright:
        Copyright (c) 2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module integrationtest.neo.common.DoublePut;

import swarm.neo.request.Command;

/*******************************************************************************

    Status code enum. Sent from the node to the client.

*******************************************************************************/

public enum RequestStatusCode : StatusCode
{
    None,           // Invalid, default value

    Succeeded,      // Values written
    PartialSuccess, // Writing to one node succeeded
    Error           // Internal node error occurred
}
