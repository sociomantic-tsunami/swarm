/*******************************************************************************

    Common protocol definitions for the GetAll request.

    Copyright:
        Copyright (c) 2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module test.neo.common.GetAll;

import swarm.neo.request.Command;

/*******************************************************************************

    Status code enum. Sent from the node to the client at the start of the
    request.

*******************************************************************************/

public enum RequestStatusCode : StatusCode
{
    None,    // Invalid, default value

    Started, // Request handling started successfully
    Error    // Internal node error occurred
}

/*******************************************************************************

    Message type enum. Sent from the node to the client.

*******************************************************************************/

public enum MessageType : ubyte
{
    None,   // Invalid, default value

    Record, // Record transmitted; key/value present follow in this message
    End     // All records transmitted; request finished
}

