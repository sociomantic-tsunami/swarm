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
    End,    // All records transmitted; request finished

    Suspend, // Sent from the client to inform the node to suspend the iteration
    Resume,  // Sent from the client to inform the node to resume the iteration
    Stop,    // Sent from the client to inform the node to stop iterating
    Ack      // Sent from the node to let the client know that a control message
             // (e.g. Stop) has been carried out
}

