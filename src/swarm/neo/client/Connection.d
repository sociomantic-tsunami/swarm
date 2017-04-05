/*******************************************************************************

    Full-duplex client connection with authentication.

    This class is not intended to be derived from (hence declared final). This
    is a conscious design decision to avoid big class hierarchies using
    inheritance for composition. If specialisation of this class is required, at
    some point, it should be implemented via opaque blobs or Object references
    (allowing a specific implementation to associate its own, arbitrary data
    with instances).

    Copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.client.Connection;

import swarm.neo.connection.ConnectionBase;

/// ditto
public final class Connection: ConnectionBase
{
    import swarm.neo.client.IRequestSet;

    import swarm.neo.client.ClientSocket;
    import swarm.neo.protocol.connect.ClientConnect;
    import swarm.neo.authentication.Credentials;
    import swarm.neo.IPAddress;
    import swarm.neo.util.TreeMap;
    import swarm.neo.client.RetryTimer;

    import ocean.core.Enforce;
    import ocean.io.select.EpollSelectDispatcher;
    import ocean.transition;

    debug ( SwarmConn ) import ocean.io.Stdout;

    /***************************************************************************

        Object pool index.

    ***************************************************************************/

    public size_t object_pool_index;

    /***************************************************************************

        Tree map element, needed for the connection set.

    ***************************************************************************/

    struct TreeMapElement
    {
        import ocean.util.container.ebtree.c.eb64tree;
        eb64_node ebnode;
        Connection connection;

        alias connection user_element_with_treemap_backlink;
    }

    public TreeMapElement* treemap_backlink = null;


    /***************************************************************************

        The connection status.

    ***************************************************************************/

    public enum Status: uint
    {
        /***********************************************************************

            The socket is not connected. Until `start()` is called requests are
            not processed but may be registered for sending or error
            notification.

        ***********************************************************************/

        Disconnected,

        /***********************************************************************

            Establishing the socket connection including authentication is in
            progress, i.e. `start()` has been called. Until it has finished
            requests are not processed but may be registered for sending or
            error notification.

        ***********************************************************************/

        Connecting,

        /***********************************************************************

            The connection is up, processing requests.

        ***********************************************************************/

        Connected,

        /***********************************************************************

            A connection shutdown was requested. The socket is not connected.
            Passing the shutdown notification to the registered requests is in
            progress. Until the shutdown process has completed it is not
            possible to start the connection or register requests.

        ***********************************************************************/

        Shutdown
    }

    protected Status status_;

    /***************************************************************************

        The node address.

    ***************************************************************************/

    private IPAddress node_address;

    /***************************************************************************

        The node connection socket.

    ***************************************************************************/

    private ClientSocket client_socket;

    /***************************************************************************

        The request set, shared across all connections.

    ***************************************************************************/

    private IRequestSet request_set;

    /***************************************************************************

        Connects the client to the node on connection startup.

    ***************************************************************************/

    private ClientConnect conn_init;

    /***************************************************************************

        True if `sendFiberMethod()` should reconnect after a shutdown or false
        if it should terminate.

    ***************************************************************************/

    private bool restart_after_shutdown;

    /***************************************************************************

        Callback for notification when the node connection has been establised
        (`e is null` in this case) or an error happened while establishing the
        connection (`e` then reflects the error).

    ***************************************************************************/

    public alias void delegate ( Connection connection, Exception e = null ) StartupNotifier;

    private StartupNotifier startup_notifier = null;

    /***************************************************************************

        The set of requests to notify the next time when the connection to the
        node has become available, i.e. `this.status` changed to `Connected`.

    ***************************************************************************/

    private TreeMap!() connected_subscribers;

    /***************************************************************************

        Used by `shutdownAndHalt()` to signal a connection shutdown.

    ***************************************************************************/

    static class ConnectionClosedException : Exception
    {
        this ( istring file = __FILE__, typeof(__LINE__) line = __LINE__ )
        {
            super("Connection closed", file, line);
        }
    }

    /**************************************************************************

        (Copied from FiberSocketConnection)

        Delegate which is called (in EpollTiming debug mode) after a socket
        connection is established.

        FIXME: the logging of connection times was intended to be done directly
        in this module, not via a delegate, but dmd bugs with varargs made this
        impossible. The delegate solution is ok though.

     **************************************************************************/

    debug ( EpollTiming )
    {
        import ocean.time.StopWatch;
        private alias void delegate ( ulong microsec ) ConnectionTimeDg;
        public ConnectionTimeDg connection_time_dg;
    }

    /***************************************************************************

        Constructor.

        Params:
            credentials  = authentication credentials
            request_set  = the request set
            epoll        = epoll select dispatcher

    ***************************************************************************/

    public this ( Const!(Credentials) credentials, IRequestSet request_set,
                  EpollSelectDispatcher epoll )
    {
        this.client_socket = new ClientSocket;

        super(this.client_socket.socket, epoll);

        this.conn_init = new ClientConnect(credentials);
        this.request_set = request_set;
    }

    /***************************************************************************

        Starts the engine:
          - Connects to node, does the proticol handshake and authentication,
          - registers the socket for reading,
          - starts the send and receive fiber,
          - sends the messages in the queue.

        Params:
            node_address = the address of the node to connect to

        Throws:
            - `SocketError` if `socket()` failed. `connect()` is not called in
              this case.
            - `SocketError` if `connect()` failed with an error other than
              `EINPROGRESS` or `EINTR`, which are expected and handled. Other
              possible errors include
                - `EISCONN` -- the socket is already connected,
                - `EAGAIN` -- there are "no more free local ports or
                   insufficient entries in the routing cache" (Linux specific).

    ***************************************************************************/

    public Status start ( IPAddress node_address, StartupNotifier startup_notifier )
    {
        debug ( SwarmConn )
        {
            Stdout.formatln("{}:{}: Connection.start()",
                node_address.address_bytes, node_address.port);
            scope ( exit ) Stdout.formatln("{}:{}: Connection.start() exit",
                node_address.address_bytes, node_address.port);
        }

        this.node_address = node_address;
        this.startup_notifier = startup_notifier;
        this.restart_after_shutdown = true;
        super.start();
        return this.status_;
    }

    /***************************************************************************

        Returns:
            the current connection status.

    ***************************************************************************/

    public Status status ( )
    {
        return this.status_;
    }

    /***************************************************************************

        Shuts the engine down:
          - Closes the socket connection.
          - Notifies all request handlers that are waiting to send and/or
            receive a message (except for `request_id`).

        Does not reconnect to the node.

    ***************************************************************************/

    public void shutdownAndHalt ( istring file = __FILE__, typeof(__LINE__) line = __LINE__ )
    {
        this.restart_after_shutdown = false;
        
        if (this.send_loop.running)
        {
            switch (this.status_)
            {
                case this.status_.Connecting:
                    this.socket.close();
                    this.status_ = this.status_.Disconnected;
                    break;
                
                case this.status_.Connected:
                    throw new Exception(
                        "shutdownAndHalt() called from the send fiber while " ~
                        "connected", file, line);

                default:
            }
        }
        else
        {
            scope e = new ConnectionClosedException(file, line);
            this.shutdown(e);
        }
    }

    /***************************************************************************

        Updates the status on a connection shutdown.

        This method should not throw.

        Params:
            e = the exception reflecting the error

        In:
            This method must only be called in the send fiber and outside the
            sending loop (required by the super call in this method).

    ***************************************************************************/

    override protected void shutdownImpl ( Exception e ) // nothrow
    {
        this.status_ = this.status_.Shutdown;
        super.shutdownImpl(e);
        this.status_ = this.status_.Disconnected;
    }

    /***************************************************************************

        If this connection is currently not available, i.e.
        `this.status != this.status.Connected`, registers a request to be
        notified once when it has become available. The registration is removed
        automatically when the notification is done.

        Params:
            request_id = the request id

        Returns:
             - 0 if the connection is currently available so a registration for
               this request id was not added,
             - 1 if a registration for this request id was added,
             - 2 if a registration for this request id already existed.

    ***************************************************************************/

    public uint registerForConnectedNotification ( RequestId request_id )
    {
        if (this.status_ != this.status_.Connected)
        {
            bool added;
            this.connected_subscribers.put(request_id, added);
            return !added + 1;
        }
        else
        {
            return 0;
        }
    }

    /***************************************************************************

        Unregisters a request from being notified when this connection becomes
        available.

        Params:
            request_id = the request id

        Returns:
            true if the request has been unregistered or false if it was not
            registered in the first place.

    ***************************************************************************/

    public bool unregisterForConnectedNotification ( RequestId request_id )
    {
        if (auto ebnode = request_id in this.connected_subscribers)
        {
            this.connected_subscribers.remove(*ebnode);
            return true;
        }
        else
        {
            return false;
        }
    }

    /***************************************************************************

        Called from the send fiber before the send/receive loops are started.
        Connects to the node, including protocol version handshake and
        authentication, then starts the receiving and sending loop.

        If `shutdown()` is called -- in this or the super class or by a request,
        when an error happens -- the connection is automatically restarted and
        stays registered in the connection set. Calling `shutdownAndHalt()` will
        ultimately shut it down.

        Returns:
            if the connection is established: true, to start the send/receive
                loops
            if the connections attempt is aborted: false, to exit

    ***************************************************************************/

    override protected bool connect ( )
    {
        debug ( SwarmConn )
        {
            Stdout.formatln("{}:{}: Connection.connect()",
                node_address.address_bytes, node_address.port);
            scope ( exit ) Stdout.formatln("{}:{}: Connection.connect() exit",
                node_address.address_bytes, node_address.port);
        }

        if (!this.restart_after_shutdown)
            return false;

        this.status_ = this.status_.Connecting;
        retry(this.tryConnect(), this.send_loop, this.epoll);
        switch (this.status_)
        {
            case this.status_.Connecting:
                this.status_ = this.status_.Connected;
                if (this.startup_notifier !is null)
                    this.startup_notifier(this);
                this.notifyConnectedSubscribers();
                return true;

            case this.status_.Disconnected:
                /* 
                 * Shutdown was requested during startup, stopping further
                 * connection attempts.
                 */
                return false;

            default:
                assert(false);
        }
    }

    /***************************************************************************

        Calls `connect()`, catching exceptions except
        `ConnectionClosedException`, and calls the startup notifier.

        Returns:
            true if `connect()` returned or false if it threw.

        Throws:
            `ConnectionClosedException` if `connect()` threw it.

        In:
            This method must be called in the sending fiber.

    ***************************************************************************/

    private bool tryConnect ( )
    in
    {
        assert(this.send_loop.running);
    }
    body
    {
        debug ( SwarmConn )
        {
            Stdout.formatln("{}:{}: Connection.tryConnect()",
                node_address.address_bytes, node_address.port);
            scope ( exit ) Stdout.formatln("{}:{}: Connection.tryConnect() exit",
                node_address.address_bytes, node_address.port);
        }

        try
        {
            this.conn_init.connect(
                this.client_socket, this.node_address, this.send_loop,
                this.epoll, this.receiver, this.sender, this.protocol_error
            );

            debug ( SwarmConn )
                Stdout.formatln("{}:{}: Connection.tryConnect() succeeded",
                    node_address.address_bytes, node_address.port);
            return true;
        }
        catch (Exception e)
        {
            if (this.startup_notifier !is null)
                this.startup_notifier(this, e);

            debug ( SwarmConn )
                Stdout.formatln("{}:{}: Connection.tryConnect() failed with "
                    "exception '{}' @{}:{}", node_address.address_bytes,
                    node_address.port, getMsg(e), e.file, e.line);
            return false;
        }

        assert(false);
    }

    /***************************************************************************

        While `this.status` is `Connected`, calls each notifier registered via
        `registerConnectedNotification` and removes it from the list. Stops
        calling the notifiers if the status is not `Connected`.

    ***************************************************************************/

    private void notifyConnectedSubscribers ( )
    in
    {
        assert(this.status_ == this.status_.Connected);
    }
    body
    {
        foreach (ref ebnode; this.connected_subscribers)
        {
            auto id = ebnode.key;
            this.connected_subscribers.remove(ebnode);

            if (auto request_handler = this.getRequestOnConn(id))
                request_handler.reconnected();

            if (this.status_ != this.status_.Connected)
                break;
        }
    }

    /***************************************************************************

        Obtains the request-on-conn for the request according to id for this
        node.

        Params:
            id = request id

        Returns:
            the request handler for the request according to id for this node
            or null if not found.

    ***************************************************************************/

    private IRequestOnConn getRequestOnConn ( RequestId id )
    {
        if (auto request = this.request_set.getRequest(id))
        {
            return request.getHandler(this.node_address);
        }
        else
        {
            return null;
        }
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
        if (auto request_handler = this.getRequestOnConn(id))
        {
            request_handler.getPayloadForSending(send);
        }
    }

    /***************************************************************************

        Called when a request message has arrived. Passes `payload` to the
        request, if there is one waiting for a message to arrive.

        Params:
            id   = the request id
            send = the request message payload

    ***************************************************************************/

    override protected void setReceivedPayload (
        RequestId id, Const!(void)[] payload
    )
    {
        if (auto request_handler = this.getRequestOnConn(id))
        {
            request_handler.setReceivedPayload(payload);
        }
    }

    /***************************************************************************

        Called for all request ids in the message queue and the registry of
        those waiting for a message to arrive when `shutdown` was called so that
        these requests are aborted.

        `shutdown` is called by the super class if an I/O or protocol error
        happens, or by `this.shutdown`.

        If a request id is in both the message queue and the registry of
        receivers then this method is called ony once with that request id.

        This method should not throw.

        Params:
            id = the request id
            e  = the exception reflecting the reason for the shutdown

    ***************************************************************************/

    override protected void notifyShutdown ( RequestId id, Exception e )
    {
        if (auto request_handler = this.getRequestOnConn(id))
        {
            request_handler.error(e);
        }
    }
}
