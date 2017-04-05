/*******************************************************************************

    Types passed to client request notifier delegates.

    Copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.client.NotifierTypes;

/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.transition;

/*******************************************************************************

    The address of a node.

*******************************************************************************/

public struct NodeInfo
{
    import swarm.neo.IPAddress;

    /// Address of the remote node for which the notification is occurring.
    IPAddress node_addr;
}

/*******************************************************************************

    The address of a node.

*******************************************************************************/

public struct RequestNodeInfo
{
    import swarm.neo.IPAddress;
    import swarm.neo.protocol.Message : RequestId;

    /// ID of the request for which the notification is occurring.
    RequestId request_id;

    /// Address of the remote node for which the notification is occurring.
    IPAddress node_addr;
}

/*******************************************************************************

    The address of a node plus an enum indicating a type of unsupported error.

*******************************************************************************/

deprecated("Use RequestNodeUnsupportedInfo instead")
public struct NodeUnsupportedInfo
{
    import swarm.neo.IPAddress;

    /// Address of the remote node for which the notification is occurring.
    IPAddress node_addr;

    enum Type
    {
        RequestNotSupported,
        RequestVersionNotSupported
    }

    /// Type of unsupported error.
    Type type;
}

/*******************************************************************************

    The address of a node plus an enum indicating a type of unsupported error.

*******************************************************************************/

public struct RequestNodeUnsupportedInfo
{
    import swarm.neo.IPAddress;
    import swarm.neo.protocol.Message : RequestId;

    /// ID of the request for which the notification is occurring.
    RequestId request_id;

    /// Address of the remote node for which the notification is occurring.
    IPAddress node_addr;

    enum Type
    {
        RequestNotSupported,
        RequestVersionNotSupported
    }

    /// Type of unsupported error.
    Type type;
}

/*******************************************************************************

    The address of a node and an exception.

*******************************************************************************/

public struct NodeExceptionInfo
{
    import swarm.neo.IPAddress;

    /// Address of the remote node for which the notification is occurring.
    IPAddress node_addr;

    /// Exception associated with notification.
    Exception e;
}

/*******************************************************************************

    The address of a node and an exception.

*******************************************************************************/

public struct RequestNodeExceptionInfo
{
    import swarm.neo.IPAddress;
    import swarm.neo.protocol.Message : RequestId;

    /// ID of the request for which the notification is occurring.
    RequestId request_id;

    /// Address of the remote node for which the notification is occurring.
    IPAddress node_addr;

    /// Exception associated with notification.
    Exception e;
}

/*******************************************************************************

    A chunk of untyped data.

*******************************************************************************/

deprecated("Use RequestDataInfo instead")
public struct DataInfo
{
    /// Data value associated with notification.
    Const!(void)[] value;
}

/*******************************************************************************

    A chunk of untyped data.

*******************************************************************************/

public struct RequestDataInfo
{
    import swarm.neo.protocol.Message : RequestId;

    /// ID of the request for which the notification is occurring.
    RequestId request_id;

    /// Data value associated with notification.
    Const!(void)[] value;
}

/*******************************************************************************

    Dummy, empty information struct.

*******************************************************************************/

public struct NoInfo {}

/*******************************************************************************

    Just the request ID.

*******************************************************************************/

public struct RequestInfo
{
    import swarm.neo.protocol.Message : RequestId;

    /// ID of the request for which the notification is occurring.
    RequestId request_id;
}

