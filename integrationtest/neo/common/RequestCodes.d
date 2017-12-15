/*******************************************************************************

    List of request codes.

    Copyright:
        Copyright (c) 2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module integrationtest.neo.common.RequestCodes;

public enum RequestCode : ubyte
{
    None,
    Put,
    Get,
    GetAll
}
