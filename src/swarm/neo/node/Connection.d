/*******************************************************************************

    Full-duplex client connection with authentication.

    Copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.node.Connection;

/******************************************************************************/

import swarm.neo.connection.ConnectionBase;

/******************************************************************************/

class Connection: ConnectionBase
{
    import swarm.neo.protocol.Message: RequestId;
    import swarm.neo.node.RequestSet;
    import swarm.neo.protocol.connect.NodeConnect;
    import swarm.neo.authentication.HmacDef: Key;
    import swarm.neo.connection.YieldedRequestOnConns;

    import ocean.core.Enforce;
    import ocean.io.select.EpollSelectDispatcher;
    import ocean.sys.socket.AddressIPSocket;

    import core.sys.posix.netinet.in_: SOL_SOCKET, IPPROTO_TCP, SO_KEEPALIVE;

    import ocean.transition;

    debug (SwarmConn) import ocean.io.Stdout_tango;

    /***************************************************************************

        Convenience alias

    ***************************************************************************/

    alias RequestSet.RequestPool RequestPool;

    /***************************************************************************

        The request set for this connection.

    ***************************************************************************/

    private RequestSet request_set;

    /***************************************************************************

        Connection authenticator / establisher

    ***************************************************************************/

    private NodeConnect conn_init;

    /***************************************************************************

        Notifier for the user of this class (i.e. `ConnectionHandler`) when this
        connection is closed.

    ***************************************************************************/

    private void delegate ( ) when_closed;

    /***************************************************************************

        Flag for `connect`, tells whether it is called right after the client
        connection was accepted (true) or after it has shut down (false).

    ***************************************************************************/

    private bool first_connect_attempt;

    /***************************************************************************

        Flag controlling whether Nagle's algorithm is disabled (true) or left
        enabled (false) on the underlying socket.

        (The no-delay option is not generally suited to live servers, where
        efficient packing of packets is desired, but can be useful for
        low-bandwidth test setups.)

    ***************************************************************************/

    private bool no_delay;

    /***************************************************************************

        Constructor.

        Params:
            credentials = reference to the client keys by client name, can be
                          updated by the node
            socket  = the client connection socket, does not need to be
                      open or connected at this point
            epoll  = the epoll select dispatcher
            request_handler = the request handler used by this connection
            when_closed = called when this connection is closed
            request_pool = global pool of `Request` objects shared across
                           multiple instances of this class
            task_resumer = global resumer to resume yielded `RequestOnConn`s
            no_delay = if false, data written to the socket will be buffered and
                sent according to Nagle's algorithm. If true, no buffering will
                occur. (The no-delay option is not generally suited to live
                servers, where efficient packing of packets is desired, but can
                be useful for low-bandwidth test setups.)

    ***************************************************************************/

    public this ( ref Const!(Key[istring]) credentials,
                  AddressIPSocket!() socket, EpollSelectDispatcher epoll,
                  RequestSet.Handler request_handler,
                  void delegate ( ) when_closed, RequestPool request_pool,
                  YieldedRequestOnConns task_resumer, bool no_delay = false )
    {
        super(socket, epoll);
        this.request_set = new RequestSet(this, request_pool, task_resumer, request_handler);
        this.conn_init = new NodeConnect(credentials);
        this.when_closed = when_closed;
        this.no_delay = no_delay;
    }

    /***************************************************************************

        Starts the engine:
            - Initialises the connection including authentication,
            - registers the socket for reading,
            - starts the send and receive fiber.

    ***************************************************************************/

    override public void start ( )
    {
        this.first_connect_attempt = true;
        super.start();
    }

    /***************************************************************************

        Performs the connection shutdown.

        Params:
            e = the exception reflecting the error

    ***************************************************************************/

    override protected void shutdownImpl ( Exception e )
    {
        debug (SwarmConn)
        {
            Stdout.formatln("node connection shutdown \"{}\" @{}:{}", getMsg(e), e.file, e.line);
            scope (success) Stdout.formatln("node connection shutdown success");
            scope (failure) Stdout.formatln("node connection shutdown failure");
        }

        super.shutdownImpl(e);

        // super.shutdownImpl will only shutdown requests registered for
        // receiving or sending. There may also be requests that are registered
        // for neither sending nor receiving which need to be shutdown.
        this.request_set.shutdownAll(e);

        this.when_closed();
    }

    /***************************************************************************

        Called from the send fiber before the send/receive loops are started.
        Sets up the client connection socket and does the protocol version
        handshake and the client authentication.
        Expects this.socket to be connected to the client.

        Returns:
            on the first call after the client connection was accepted: true, to
                start the send/receive loops
            on subsequent calls, i.e. after a connection shutdown: false, to
                exit

        Throws:
            - `ProtocolError` on incompatible client/node protocol version,
            - `ProtocolError` on message protocol error,
            - `HmacAuthCode.RejectedException` if the the authentication was
              rejected,
            - `IOError` on I/O or socket error.

    ***************************************************************************/

    override protected bool connect ( )
    {
        if ( !this.first_connect_attempt )
            return false;

        this.first_connect_attempt = false;

        if ( this.no_delay )
            this.socket.setsockoptVal(IPPROTO_TCP,
                socket.TcpOptions.TCP_NODELAY, true);

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

        // If authentication fails the connection is simply disconnected and
        // returned to the pool.

        this.conn_init.authenticate(this.socket.fd, this.send_loop, this.epoll,
                                  this.receiver, this.sender,
                                  this.protocol_error_);

        return true;
    }

    /***************************************************************************

        Called with a request id that was just popped from the message queue.
        Passes the payload of the message this request wants to `send`.
        If the request not exist any more, for whatever reason, then `send` is
        not called.

        Params:
            id   = the request id
            send = the output delegate to call once with the message payload

    ***************************************************************************/

    override protected void getPayloadForSending (
        RequestId id, void delegate ( void[][] payload ) send
    )
    {
        if (auto request = this.request_set.getRequest(id))
        {
            request.getPayloadForSending(send);
        }
    }

    /***************************************************************************

        Called when a request message has arrived. Passes `payload` to the
        request, if there is one waiting for a message to arrive.

        Params:
            id   = the request id
            send = the request message payload

    ***************************************************************************/

    override protected void setReceivedPayload ( RequestId id, Const!(void)[] payload )
    {
        this.request_set.getOrCreateRequest(id).setReceivedPayload(payload);
    }

    /***************************************************************************

        Called for all request ids in the message queue and the registry of
        those waiting for a message to arrive when `shutdown` was called so that
        these requests are aborted.

        `shutdown` is called by the super class if an I/O or protocol error
        happens.

        If a request id is in both the message queue and the registry of
        receivers then this method is called ony once with that request id.

        This method should not throw.

        Params:
            id = the request id
            e  = the exception reflecting the reason for the shutdown

    ***************************************************************************/

    override protected void notifyShutdown ( RequestId id, Exception e )
    {
        if (auto request = this.request_set.getRequest(id))
        {
            request.error(e);
        }
    }
}
