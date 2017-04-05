/*******************************************************************************

    created:        2013-04-11 by Leandro Lucarella

    Helper class for detecting when a socket disconnection occurs. Useful for
    commands that wait until something external happens and then send data to
    the client (in which case the disconnection is only detected when something
    actually happens and the command tries to write to the socket).

    copyright:      Copyright (c) 2012-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.common.request.helper.DisconnectDetector;



/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.io.select.client.model.ISelectClient;



/*******************************************************************************

    Watches for EPOLLIN and EPOLLRDHUP events to detect disconnections.

    This class assumes any EPOLLIN event is a protocol error, and reports it as
    a disconnection.

    This class doesn't perform heap allocations, so you can use it as a scope
    class safely.

*******************************************************************************/

public class DisconnectDetector : ISelectClient
{

    /***************************************************************************

        Action to trigger when a disconnection is detected.

    ***************************************************************************/

    public alias void delegate ( ) DisconnectionHandler;

    /***************************************************************************

        Delegate to execute when a disconnection is detected.

    ***************************************************************************/

    protected DisconnectionHandler disconnection_handler;

    /***************************************************************************

        File descriptor we want to monitor for disconnections.

    ***************************************************************************/

    protected Handle fd;

    /***************************************************************************

        Disconnection flag (set to true when an even is received).

    ***************************************************************************/

    protected bool _disconnected;

    /***************************************************************************

        Constructor.

        Params:
            fd = File descriptor where to detect disconnections
            handler = Delegate to call when a disconnection is detected

    ***************************************************************************/

    public this ( Handle fd, DisconnectionHandler handler )
    {
        assert (fd != -1, "You have to provide a valid open file descriptor");
        assert (handler !is null, "You need to provide a non-null handler");

        this.fd = fd;
        this.disconnection_handler = handler;
        this._disconnected = false;
    }

    /***************************************************************************

        True if a disconnection has been detected.

    ***************************************************************************/

    public bool disconnected ( )
    {
        return this._disconnected;
    }

    /***************************************************************************

        File handle to register in epoll.

    ***************************************************************************/

    public override Handle fileHandle ( )
    {
        return this.fd;
    }

    /***************************************************************************

        Events to listen to via epoll.

    ***************************************************************************/

    public override Event events ( )
    {
        return Event.EPOLLIN | Event.EPOLLRDHUP;
    }

    /***************************************************************************

        Handle an incoming event.

        This is just a dummy handler, the real logic is in finalize().

        Params:
             event = identifier of I/O event that just occured on the device

        Returns:
            false so it never get re-registered.

    ***************************************************************************/

    public override bool handle ( Event event )
    {
        return false;
    }

    /***************************************************************************

        Handle the finalization of the select client.

        Basically sets the disconnected flag to true if a disconnection was
        detected (which is the only way this event can be triggered. Right now
        receiving anything or a hungup is considered a disconnection, so this is
        only valid for protocols where receiving anything is an error and thus
        disconnecting is a valid option.

        Params:
            status = status why this method is called

    ***************************************************************************/

    public override void finalize ( FinalizeStatus status )
    {
        this._disconnected = true;

        this.disconnection_handler();
    }

}


