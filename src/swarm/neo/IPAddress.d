/*******************************************************************************

    IP address (v4).

    copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.IPAddress;

import swarm.neo.AddrPort;

deprecated("IPAddress has been renamed to AddrPort, see swarm.neo.AddrPort")
public alias AddrPort IPAddress;
