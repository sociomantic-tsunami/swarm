/*******************************************************************************

    Fiber-based socket connection handler. Extends the base class in ocean,
    adding an extra socket initialisation step to set various parameters for
    TCP keepalive and SYN retransmits.

    copyright:      Copyright (c) 2012-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.connection.FiberSocketConnection;



/*******************************************************************************

    Imports

*******************************************************************************/

import Ocean = ocean.io.select.protocol.fiber.FiberSocketConnection;

import core.sys.posix.netinet.in_: SOL_SOCKET, IPPROTO_TCP, SO_KEEPALIVE;

public class FiberSocketConnection : Ocean.FiberSocketConnection!()
{
    /***************************************************************************

        Interface to receive notification when the socket connection is
        disconnected.

    ***************************************************************************/

    public interface IDisconnectionHandler
    {
        void onDisconnect ( );
    }


    /***************************************************************************

        Disconnection handler (optional, may be null). The interface's
        onDisconnect() method will be called when the connection is
        disconnected.

    ***************************************************************************/

    private IDisconnectionHandler on_disconnect;


    /***************************************************************************

        Constructor. Creates a new Socket instance internally.

        Params:
            fiber = fiber to use to suspend and resume operation
            on_disconnect = disconnection handler (optional, may be null)

    ***************************************************************************/

    public this ( SelectFiber fiber, IDisconnectionHandler on_disconnect = null )
    {
        this(new IPSocket, fiber, on_disconnect);
    }


    /***************************************************************************

        Constructor. Uses the passed Socket instance.

        Params:
            socket = socket to connect
            fiber = fiber to use to suspend and resume operation
            on_disconnect = disconnection handler (optional, may be null)

    ***************************************************************************/

    public this ( IPSocket socket, SelectFiber fiber,
        IDisconnectionHandler on_disconnect = null )
    {
        this.on_disconnect = on_disconnect;

        super(socket, fiber);
    }


    /***************************************************************************

        Disconnecion cleanup handler, called by super class. In turn calls the
        disconnect handler passed to the constructor (if non-null).

    ***************************************************************************/

    override protected void onDisconnect ( )
    {
        if ( this.on_disconnect )
        {
            this.on_disconnect.onDisconnect();
        }
    }


    /***************************************************************************

        Called just before the socket is connected. The base class
        implementation does nothing, but derived classes may override to add any
        desired initialisation logic.

    ***************************************************************************/

    override protected void initSocket ( )
    {
        this.enableKeepalive();
        this.setSYNRetransmits(1);
    }


    /***************************************************************************

        Enables keep alive for this socket with:

            * idle time = 5 (seconds)
            * number of probes = 3 (amount)
            * time between probes = 3 (seconds)

        Values have been chosen as a rough guess of what should work well.

    ***************************************************************************/

    private void enableKeepalive ( )
    {
        // Activates TCP's keepalive feature for this socket.
        this.socket.setsockoptVal(SOL_SOCKET, SO_KEEPALIVE, true);

        // Socket idle time in seconds after which TCP will start sending
        // keepalive probes.
        this.socket.setsockoptVal(IPPROTO_TCP, socket.TcpOptions.TCP_KEEPIDLE, 5);

        // Maximum number of keepalive probes before the connection is declared
        // dead and dropped.
        this.socket.setsockoptVal(IPPROTO_TCP, socket.TcpOptions.TCP_KEEPCNT, 3);

        // Time in seconds between keepalive probes.
        this.socket.setsockoptVal(IPPROTO_TCP, socket.TcpOptions.TCP_KEEPINTVL, 3);
    }


    /***************************************************************************

        Changes the number of SYNs TCP sends for an inital connection request to
        1 to detect dead servers faster.

        Values have been chosen as a rough guess of what should work well.

    ***************************************************************************/

    private void setSYNRetransmits ( int retransmits )
    {
        // Limits the number of SYN retransmits to make before an attempt to
        // connect is aborted.
        this.socket.setsockoptVal(IPPROTO_TCP, socket.TcpOptions.TCP_SYNCNT, retransmits);
    }
}
