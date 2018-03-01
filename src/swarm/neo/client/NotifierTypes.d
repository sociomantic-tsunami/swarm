/*******************************************************************************

    Types passed to client request notifier delegates.

    Copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.neo.client.NotifierTypes;

/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.transition;
import swarm.neo.util.Formatter;

/*******************************************************************************

    The address of a node.

*******************************************************************************/

public struct NodeInfo
{
    import swarm.neo.AddrPort;

    /// Address of the remote node for which the notification is occurring.
    AddrPort node_addr;

    /***************************************************************************

        Formats a description of the notification to the provided sink delegate.

        Params:
            sink = delegate to feed formatted strings to

    ***************************************************************************/

    public void toString ( scope void delegate ( cstring chunk ) sink )
    {
        sformat(sink,
            "Node {}:{}",
            (&this).node_addr.address_bytes, (&this).node_addr.port);
    }
}

/*******************************************************************************

    The address of a node.

*******************************************************************************/

public struct RequestNodeInfo
{
    import swarm.neo.AddrPort;
    import swarm.neo.protocol.Message : RequestId;

    /// ID of the request for which the notification is occurring.
    RequestId request_id;

    /// Address of the remote node for which the notification is occurring.
    AddrPort node_addr;

    /***************************************************************************

        Formats a description of the notification to the provided sink delegate.

        Params:
            sink = delegate to feed formatted strings to

    ***************************************************************************/

    public void toString ( scope void delegate ( cstring chunk ) sink )
    {
        sformat(
            sink,
            "Request #{}, node {}:{}",
            (&this).request_id, (&this).node_addr.address_bytes, (&this).node_addr.port);
    }
}

/*******************************************************************************

    The address of a node plus an enum indicating a type of unsupported error.

*******************************************************************************/

public struct RequestNodeUnsupportedInfo
{
    import swarm.neo.AddrPort;
    import swarm.neo.protocol.Message : RequestId;

    /// ID of the request for which the notification is occurring.
    RequestId request_id;

    /// Address of the remote node for which the notification is occurring.
    AddrPort node_addr;

    enum Type
    {
        RequestNotSupported,
        RequestVersionNotSupported
    }

    /// Type of unsupported error.
    Type type;

    /***************************************************************************

        Formats a description of the notification to the provided sink delegate.

        Params:
            sink = delegate to feed formatted strings to

    ***************************************************************************/

    public void toString ( scope void delegate ( cstring chunk ) sink )
    {
        sformat(
            sink,
            "Request #{}, node {}:{} reported that the {} is not supported",
            (&this).request_id, (&this).node_addr.address_bytes, (&this).node_addr.port,
            (&this).type_explanation);
    }

    /***************************************************************************

        Returns:
            a string explaining this.type

    ***************************************************************************/

    private istring type_explanation ( )
    {
        with ( Type ) switch ( (&this).type )
        {
            case RequestNotSupported:
                return "request";
            case RequestVersionNotSupported:
                return "request version";
            default:
                assert(false);
        }
        assert(false);
    }
}

/*******************************************************************************

    The address of a node and an exception.

*******************************************************************************/

public struct NodeExceptionInfo
{
    import swarm.neo.AddrPort;

    /// Address of the remote node for which the notification is occurring.
    AddrPort node_addr;

    /// Exception associated with notification.
    Exception e;

    /***************************************************************************

        Formats a description of the notification to the provided sink delegate.

        Params:
            sink = delegate to feed formatted strings to

    ***************************************************************************/

    public void toString ( scope void delegate ( cstring chunk ) sink )
    {
        if ( (&this).e !is null )
        {
            sformat(sink,
                "Exception '{}' @ {}:{} occurred in the client while handling the "
                "request on node {}:{}",
                getMsg((&this).e), (&this).e.file, (&this).e.line,
                (&this).node_addr.address_bytes, (&this).node_addr.port);
        }
        else
        {
            sformat(sink,
                "An undefined error (null Exception) occurred in the client "
                "while handling the request on node {}:{}",
                (&this).node_addr.address_bytes, (&this).node_addr.port);
        }
    }
}

/*******************************************************************************

    The address of a node and an exception.

*******************************************************************************/

public struct RequestNodeExceptionInfo
{
    import swarm.neo.AddrPort;
    import swarm.neo.protocol.Message : RequestId;

    /// ID of the request for which the notification is occurring.
    RequestId request_id;

    /// Address of the remote node for which the notification is occurring.
    AddrPort node_addr;

    /// Exception associated with notification.
    Exception e;

    /***************************************************************************

        Formats a description of the notification to the provided sink delegate.

        Params:
            sink = delegate to feed formatted strings to

    ***************************************************************************/

    public void toString ( scope void delegate ( cstring chunk ) sink )
    {
        if ( (&this).e !is null )
        {
            sformat(sink,
                "Exception '{}' @ {}:{} occurred in the client while handling "
                "request #{} on node {}:{}",
                getMsg((&this).e), (&this).e.file, (&this).e.line, (&this).request_id,
                (&this).node_addr.address_bytes, (&this).node_addr.port);
        }
        else
        {
            sformat(sink,
                "An undefined error (null Exception) occurred in the client "
                "while handling request #{} on node {}:{}",
                (&this).request_id, (&this).node_addr.address_bytes,
                (&this).node_addr.port);
        }
    }
}

/*******************************************************************************

    A chunk of untyped data.

*******************************************************************************/

public struct RequestDataInfo
{
    import swarm.neo.protocol.Message : RequestId;
    import swarm.neo.client.mixins.DeserializeMethod;

    /// ID of the request for which the notification is occurring.
    RequestId request_id;

    /// Data value associated with notification.
    Const!(void)[] value;

    /// Template method to deserialize `value` as a given struct.
    mixin DeserializeMethod!(value);

    /***************************************************************************

        Formats a description of the notification to the provided sink delegate.

        Params:
            sink = delegate to feed formatted strings to

    ***************************************************************************/

    public void toString ( scope void delegate ( cstring chunk ) sink )
    {
        sformat(sink,
            "Request #{} provided the value {}",
            (&this).request_id, (&this).value);
    }
}

/*******************************************************************************

    Dummy, empty information struct.

*******************************************************************************/

public struct NoInfo
{
    /***************************************************************************

        Formats a description of the notification to the provided sink delegate.

        Params:
            sink = delegate to feed formatted strings to

    ***************************************************************************/

    public void toString ( scope void delegate ( cstring chunk ) sink )
    {
        sink("(empty notification)");
    }
}

/*******************************************************************************

    Just the request ID.

*******************************************************************************/

public struct RequestInfo
{
    import swarm.neo.protocol.Message : RequestId;

    /// ID of the request for which the notification is occurring.
    RequestId request_id;

    /***************************************************************************

        Formats a description of the notification to the provided sink delegate.

        Params:
            sink = delegate to feed formatted strings to

    ***************************************************************************/

    public void toString ( scope void delegate ( cstring chunk ) sink )
    {
        sformat(sink,
            "Request #{}",
            (&this).request_id);
    }
}
