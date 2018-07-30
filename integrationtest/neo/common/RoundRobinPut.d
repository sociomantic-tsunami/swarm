/*******************************************************************************

    Common protocol definitions for the RoundRobinPut request.

    Copyright:
        Copyright (c) 2018 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module integrationtest.neo.common.RoundRobinPut;

/*******************************************************************************

    Message type enum. Sent from the node to the client.

*******************************************************************************/

public enum MessageType : ubyte
{
    None,       // Invalid, default value

    Succeeded,  // Value written
    Error       // Internal node error occurred
}
