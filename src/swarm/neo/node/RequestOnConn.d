/*******************************************************************************

    Node request handler.

    When a request is started, the node specific request handler method is
    started in a fiber, receiving a RequestOnConn object, which it should use
    for request message I/O.

    Copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.node.RequestOnConn;

/******************************************************************************/

import swarm.neo.connection.RequestOnConnBase;

/*******************************************************************************

    This class inherits the following public API properties:

     - `recv_payload` and `send_payload` class variables
     - `suspendFiber` and `resumeFiber` class methods

*******************************************************************************/

abstract class RequestOnConn: RequestOnConnBase
{
    import swarm.neo.protocol.Message: RequestId;
    import swarm.neo.connection.ConnectionBase;
    import swarm.neo.connection.YieldedRequestOnConns;
    import swarm.neo.util.MessageFiber;

    import ocean.transition;

    /***************************************************************************

        The event dispatcher to communicate to the client.

    ***************************************************************************/

    private EventDispatcher event_dispatcher_;

    /***************************************************************************

        Returns:
            The event dispatcher to communicate to the client.

    ***************************************************************************/

    public EventDispatcher event_dispatcher ( )
    {
        return this.event_dispatcher_;
    }

    /***************************************************************************

        Returns:
            the request id.

    ***************************************************************************/

    public RequestId getRequestId ( )
    {
        return this.request_id;
    }

    /***************************************************************************

        Constructor.

        Params:
            yielded_rqonconns = resumes yielded `RequestOnConn`s

    ***************************************************************************/

    protected this ( YieldedRequestOnConns yielded_rqonconns )
    {
        super(yielded_rqonconns);
        this.event_dispatcher_ = this.new EventDispatcher;
    }
}
