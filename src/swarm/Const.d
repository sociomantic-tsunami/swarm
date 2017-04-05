/*******************************************************************************

    Client & node constants

    copyright:      Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.Const;



/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.core.Enum;

import ocean.io.digest.Fnv1;

import ocean.transition;
import core.stdc.ctype : isalnum;



/*******************************************************************************

    Command codes base enum. Contains codes shared between all systems.

*******************************************************************************/

public class ICommandCodes : IEnum
{
    mixin EnumBase!([
        "None"[]:0  // 0x0 -- default / invalid
        ]);
}



/*******************************************************************************

    Status codes base enum. Contains codes shared between all systems.

    TODO: some of these codes are not generic, assuming concepts of channels or
    storage engines.

*******************************************************************************/

public class IStatusCodes : IEnum
{
    mixin EnumBase!([
        "Undefined"[]:                0,   // 0x0 -- default / invalid
        "Ok":                         200,
        "InvalidRequest":             400,
        "WrongNode":                  404, // TODO: not generic
        "NotSupported":               406, // TODO: not generic
        "OutOfMemory":                407, // TODO: not generic
        "EmptyValue":                 408, // TODO: not generic
        "BadChannelName":             409, // TODO: not generic
        "ValueTooBig":                410, // TODO: not generic
        "Error":                      500
        ]);
}



/*******************************************************************************

    Node item -- stores the address and port of a node

*******************************************************************************/

public struct NodeItem
{
    /***************************************************************************

        Node address & port.

    ***************************************************************************/

    public mstring Address;

    public ushort Port = 0;


    /***************************************************************************

        Returns:
            true if the node address and port are set

    ***************************************************************************/

    public bool set ( )
    {
        return this.Address.length > 0 && this.Port > 0;
    }


    /***************************************************************************

        Returns:
            hash of node (for associative array compatibility)

    ***************************************************************************/

    public hash_t toHash ( )
    {
        return Fnv1a(this.Address) ^ this.Port;
    }


    /***************************************************************************

        opEquals for associative array compatibility.

    ***************************************************************************/

    public int opEquals ( NodeItem* nodeitem )
    {
        return this.opEquals(*nodeitem);
    }


    /***************************************************************************

        opEquals for associative array compatibility.

    ***************************************************************************/

    version (D_Version2)
    {
        mixin(`
        public equals_t opEquals ( const NodeItem nodeitem ) const
        {
            return nodeitem.Address == this.Address && nodeitem.Port == this.Port;
        }
        `);
    }
    else
    {
        public equals_t opEquals ( NodeItem nodeitem )
        {
            return nodeitem.Address == this.Address && nodeitem.Port == this.Port;
        }
    }

    /***************************************************************************

        opCmp for associative array compatibility.

    ***************************************************************************/

    public mixin (genOpCmp(`
    {
        if ( this.Address > rhs.Address ) return 1;
        if ( this.Address < rhs.Address ) return -1;
        if ( this.Port > rhs.Port ) return 1;
        if ( this.Port < rhs.Port ) return -1;

        return 0;
    }`));
}



/*******************************************************************************

    Checks whether the given channel name is valid. Channel names can only
    contain ASCII alphanumeric characters, underscores or dashes. Channel names
    of length 0 are also invalid.

    Params:
        channel = channel name to check

    Returns:
        true if the channel name is valid

*******************************************************************************/

public bool validateChannelName ( cstring channel )
{
    if ( channel.length == 0 )
    {
        return false;
    }

    foreach ( c; channel )
    {
        if ( !isalnum(c) && c != '_' && c != '-' )
        {
            return false;
        }
    }

    return true;
}
