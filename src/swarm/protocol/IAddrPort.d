/*******************************************************************************

    Interface for getting an IP address / port.

    copyright: Copyright (c) 2017 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.protocol.IAddrPort;

import ocean.meta.types.Qualifiers;

/// ditto
public interface IAddrPort
{
    /***************************************************************************

        Returns: the address

    ***************************************************************************/

    public cstring address ( );

    /***************************************************************************

        Returns: the port

    ***************************************************************************/

    public ushort port ( );
}
