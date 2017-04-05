/*******************************************************************************

    Initialises a connection in the client to a node.

    Copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.protocol.connect.ClientConnect;

class ClientConnect
{
    import swarm.neo.client.ClientSocket;
    import swarm.neo.protocol.connect.ConnectProtocol;
    import swarm.neo.protocol.Message: MessageType;
    import swarm.neo.protocol.socket.MessageReceiver;
    import swarm.neo.protocol.socket.MessageSender;
    import swarm.neo.protocol.ProtocolError;
    import swarm.neo.authentication.HmacAuthCode;
    import swarm.neo.authentication.Credentials;
    import swarm.neo.authentication.HmacDef;
    import swarm.neo.IPAddress;
    import swarm.neo.util.MessageFiber;

    import ocean.io.select.EpollSelectDispatcher;

    import core.stdc.errno: errno, EINPROGRESS, EINTR;
    import core.stdc.time: time;

    import ocean.core.Enforce;

    import ocean.transition;

    debug ( SwarmConn ) import ocean.io.Stdout;

    /***************************************************************************

        The credentials for authentication.

    ***************************************************************************/

    private Credentials credentials;

    /***************************************************************************

        ConnectProtocol instance used internally.

    ***************************************************************************/

    private ConnectProtocol protocol;

    /***************************************************************************

        Exception to throw on rejected HMAC, instantiated on first use.

    ***************************************************************************/

    private HmacAuthCode.RejectedException hmac_rejected_e;

    /***************************************************************************

        Constructor.

        Params:
            credentials = the credentials for authentication.

    ***************************************************************************/

    public this ( Const!(Credentials) credentials )
    {
        this.credentials = Credentials(credentials.name.dup, credentials.key);
        this.protocol = new ConnectProtocol;
    }

    /***************************************************************************

        Waits for establishing the connection to the node, as initiated by
        calling `startConnect()` before, to complete, and performs the protocol
        handshake and authentication.

        Params:
            socket_fd = the file descriptor of the socket connection to the node
            fiber     = the fiber to suspend to wait for I/O notification
            epoll     = the epoll select dispatcher
            receiver  = the message receiver
            sender    = the message sender
            protocol_e = th exception to throw on protocol error

        Throws:
            - `HmacAuthCode.RejectedException` if the node rejected the
               authentication,
            - `protocol_e` on protocol error, including that
              - the node hung up,
              - the protocol handshake failed;
            - `IOError` on I/O or socket error.

    ***************************************************************************/

    public void connect (
        ClientSocket socket, IPAddress node_address, MessageFiber fiber,
        EpollSelectDispatcher epoll, MessageReceiver receiver,
        MessageSender sender, ProtocolError protocol_e
    )
    {
        debug ( SwarmConn )
        {
            Stdout.formatln("{}:{}: ClientConnect.connect()",
                node_address.address_bytes, node_address.port);
            scope ( exit ) Stdout.formatln("{}:{}: ClientConnect.connect() exit",
                node_address.address_bytes, node_address.port);
        }

        /*
         * Create the socket and initiate a non-blocking connect() to the node.
         */
        bool connect_in_progress = false;

        scope (failure) socket.socket.close();

        if (!socket.connect(node_address))
        {
            switch (errno)
            {
                case EINPROGRESS,
                     EINTR: // TODO: Might never be reported, see note above.
                    /*
                     * EINPROGRESS: Establishing the connection would make
                     * connect() block so we need to wait for EPOLLOUT to be
                     * notified when the connection has been established.
                     * This is done in the fiber by initConnect().
                     */
                    connect_in_progress = true;
                    break;

                case 0:
                    break;

                default:
                    throw socket.error.setSock(errno, "Error establishing connection");
            }
        }

        this.protocol.initialise(MessageType.Authentication, protocol_e, epoll,
            fiber, socket.socket.fd, receiver, sender);
        scope ( exit ) this.protocol.unregisterEpoll();

        if (connect_in_progress)
        {
            /*
             * Establishing the connection would have made connect() block so we
             * need to wait for EPOLLOUT to be notified when the connection has
             * been established.
             */
            protocol.registerEpoll(protocol.Event.EPOLLOUT);
            auto ev = protocol.wait();
            protocol_e.enforce(!(ev & protocol.Event.EPOLLHUP),
                "Node hung up on connect");
        }

        debug ( SwarmConn )
            Stdout.formatln("{}:{}: ClientConnect.connect() succeeded",
                node_address.address_bytes, node_address.port);

        this.authenticate(protocol, node_address);
    }

    /***************************************************************************

        Performs the protocol version information handshake and the
        authentication.

        The last step of the authentication procedure is a message sent by the
        node telling the client if access has been granted or denied.

        Params:
            protocol = sequential, i.e. half-duplex message protocol I/O helper
            node_address = address/port of node being connected to (only
                required for debug printouts)

        Throws:
            - `ProtocolError` on incompatible client/node protocol version,
            - `HmacAuthCode.RejectedException` if the node rejected the
               authentication,
            - `ProtocolError` on message protocol error or if the node hung up.

    ***************************************************************************/

    private void authenticate ( ConnectProtocol protocol,
        IPAddress node_address )
    {
        debug ( SwarmConn )
            Stdout.formatln("{}:{}: ClientConnect.autenticate()",
                node_address.address_bytes, node_address.port);

        const protocol_version = 1;

        protocol.sendProtocolVersion(protocol_version);
        debug ( SwarmConn )
            Stdout.formatln("{}:{}: Auth: Sent client protocol version = {}",
                node_address.address_bytes, node_address.port, protocol_version);
        ubyte node_protocol_version = protocol.receiveProtocolVersion();
        debug ( SwarmConn )
            Stdout.formatln("{}:{}: Auth: Read node protocol version = {}",
                node_address.address_bytes, node_address.port,
                node_protocol_version);

        protocol.checkVersion(protocol_version, node_protocol_version);
        debug ( SwarmConn )
            Stdout.formatln("{}:{}: Auth: Protocol versions match",
                node_address.address_bytes, node_address.port);

        // Send timestamp to node. Note that on Linux time(null) cannot fail and
        // always returns a non-negative value.
        static assert(is(typeof(time(null)) == long));
        ulong timestamp = time(null);
        debug ( SwarmConn ) Stdout.formatln("{}:{}: Auth: Timestamp={}",
            node_address.address_bytes, node_address.port, timestamp);
        protocol.send(timestamp);

        // Read nonce from node.
        auto nonce = protocol.receiveValue!(Nonce)();

        // Generate code and send with name to node
        auto auth_code = HmacAuthCode.createHmac(this.credentials.key.content,
            timestamp, nonce.content);

        debug ( SwarmConn )
            Stdout.formatln("{}:{}: Auth: Nonce={}, Name={}, Encoded={:X}",
                node_address.address_bytes, node_address.port,
                nonce.content, this.credentials.name, auth_code.content);

        protocol.send(this.credentials.name, auth_code);

        auto ok = protocol.receiveValue!(bool)();

        enforce(
            {
                if (!this.hmac_rejected_e)
                {
                    this.hmac_rejected_e = new HmacAuthCode.RejectedException;
                }
                return this.hmac_rejected_e
                    .set("Node rejected authentication")
                    .setAuthParams(timestamp, nonce.content,
                                   this.credentials.name, auth_code.content);
            }(),
            ok
        );

        debug ( SwarmConn )
            Stdout.formatln("{}:{}: ClientConnect.autenticate() succeeded",
                node_address.address_bytes, node_address.port);
    }
}
