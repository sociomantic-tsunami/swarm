/*******************************************************************************

    Initialises a connection in the node to a client.

    Copyright: Copyright (c) 2016-2017 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.neo.protocol.connect.NodeConnect;


class NodeConnect
{
    import swarm.neo.protocol.connect.ConnectProtocol;
    import swarm.neo.protocol.socket.MessageReceiver;
    import swarm.neo.protocol.socket.MessageSender;
    import swarm.neo.protocol.Message: MessageType;
    import swarm.neo.protocol.ProtocolError;

    import swarm.neo.authentication.HmacAuthCode;
    import HmacDef = swarm.neo.authentication.HmacDef;
    import Credentials = swarm.neo.authentication.Credentials;
    import swarm.neo.util.MessageFiber;

    import ocean.io.select.EpollSelectDispatcher;

    import ocean.math.Math: abs;
    import core.stdc.time: time_t, time;
    import core.stdc.ctype: isalnum;
    import ocean.core.Enforce;
    import ocean.core.Verify;
    import ocean.core.array.Mutation : copy;
    import ocean.meta.types.Qualifiers;
    import ocean.util.log.Logger;

    debug ( SwarmConn ) import ocean.io.Stdout_tango;


    /***************************************************************************

        Logger (shared by all instances).

    ***************************************************************************/

    protected static Logger log;

    static this ( )
    {
        log = Log.lookup("swarm.neo.protocol.connect.NodeConnect");
    }

    /***************************************************************************

        Reference to the client keys by client name, can be updated by the node

    ***************************************************************************/

    private const(HmacDef.Key[string])* credentials;

    /***************************************************************************

        ConnectProtocol instance used internally.

    ***************************************************************************/

    private ConnectProtocol protocol;

    /***************************************************************************

        Reusable exception.

    ***************************************************************************/

    private HmacAuthCode.RejectedException e_auth_rejected;

    /// Name of the client. Non-empty only after connection has succeeded.
    private mstring client_name;

    /***************************************************************************

        Constructor.

        Params:
            credentials = reference to the client keys by client name, can be
                          updated by the node

    ***************************************************************************/

    public this ( ref const(HmacDef.Key[string]) credentials )
    {
        this.credentials = &credentials;
        this.e_auth_rejected = new HmacAuthCode.RejectedException;
        this.protocol = new ConnectProtocol;
    }

    /***************************************************************************

        Does the protocol version handshake and the client authentication.

        Rejects the authentication if
          - the absolute difference between the client and node timestamp is
            greater than 30s, with separate error messages for a zero or
            negative client timestamp,
          - the client name is unknown, with separate error messages for an
            empty, too long or invalid characters containing client name.

        Params:
            socket_fd  = client connection socket file descriptor
            fiber      = the fiber to use to wait for socket I/O
            epoll      = the epoll select dispatchar
            receiver   = the message receiver
            sender     = the message sender
            protocol_e = the exception to throw on protocol error


        Throws:
            - `HmacAuthCode.RejectedException` if the authentication was
              rejected,
            - `protocol_e` on protocol error, including that the protocol
              handshake failed;
            - `IOError` on I/O or socket error.

    ***************************************************************************/

    public void authenticate ( int socket_fd, MessageFiber fiber,
                               EpollSelectDispatcher epoll,
                               MessageReceiver receiver, MessageSender sender,
                               ProtocolError protocol_e )
    {
        this.protocol.initialise(MessageType.Authentication, protocol_e, epoll,
            fiber, socket_fd, receiver, sender);
        scope ( exit ) this.protocol.unregisterEpoll();

        static immutable request_type     = MessageType.Authentication,
              protocol_version = 1;

        ubyte client_protocol_version = this.protocol.receiveProtocolVersion();
        debug ( SwarmConn )
            Stdout.formatln("Read client protocol version = {}",
                client_protocol_version);
        this.protocol.sendProtocolVersion(protocol_version);
        debug ( SwarmConn )
            Stdout.formatln("Sent node protocol version = {}",
                protocol_version);

        this.protocol.checkVersion(client_protocol_version, protocol_version);
        debug ( SwarmConn )
            Stdout.formatln("Protocol versions match");

        /*
         * Read time stamps from client and node real-time clock. Both time
         * stamps must be <= time_t.max when cast to ulong:
         *   - The node time stamp is always in these bounds because it is
         *     obtained from time(null), and time(null) cannot possibly fail
         *     on Linux according to the manpage, which is the only case when
         *     it returns a negative value.
         *   - For the client time stamp the protocol type is already ulong so
         *     it is validated to be in that range.
         */
        static assert(is(time_t == long));
        long node_timestamp = time(null);
        auto client_timestamp = this.protocol.receiveValue!(ulong)();

        // Send nonce to client.
        auto nonce = HmacAuthCode.createNonce();
        this.protocol.send(nonce.content);

        /*
         * Read name and code from client and do the actual authentication.
         * This flag is also for robustness against bugs, should the
         * authenticate() callback not be called or an exception be swallowed.
         */
        bool success = false;

        this.e_auth_rejected.resetAuthParams();

        // receive() callback, does the authentication.
        void authenticate ( cstring client_name, HmacDef.Code client_code )
        {
            try
            {
                this.client_name.copy(client_name);

                // Validate the client name.
                enforce(this.e_auth_rejected.set("Empty client name"),
                        client_name.length);
                enforce(this.e_auth_rejected.set("Client name too long"),
                        client_name.length <= Credentials.LengthLimit.Name);

                // Look up the key by client name.
                if (auto key = client_name in (*this.credentials))
                {
                    // Validate the time stamp.
                    this.validateTimeStamp(client_timestamp, node_timestamp);

                    // Do the authentication, throw if rejected.
                    enforce(
                        this.e_auth_rejected.set("Client authentication rejected"),
                        HmacAuthCode.confirm(
                            (*key).content, client_timestamp, nonce.content,
                            client_code.content
                        )
                    );

                    // Authentication successful.
                    success = true;
                }
                else
                {   // Client name not found: Extra check for invalid name,
                    // throw in any case
                    enforce(
                        this.e_auth_rejected.set("Invalid character in client name"),
                        !Credentials.validateNameCharacters(client_name)
                    );
                    throw this.e_auth_rejected.set("Unknown client name");
                }
            }
            catch (HmacAuthCode.RejectedException e)
            {
                throw e.setAuthParams(client_timestamp, nonce.content,
                                      client_name, client_code.content);
            }
        }

        /*
         * Catch a rejection exception here and because we need to send the
         * success = false message to the client in this case; rethrow after
         * sending.
         */
        try
        {
            this.protocol.receive(&authenticate);
        }
        catch (HmacAuthCode.RejectedException e)
        {
            success = false;
        }

        this.protocol.send(success);

        if (!success)
        {
            log.warn("Authentication failure for client '{}': {}",
                this.client_name, this.e_auth_rejected.message);

            this.client_name.length = 0;
            assumeSafeAppend(this.client_name);
            throw this.e_auth_rejected;
        }

        // Make sure we return normally only if the authentication was accepted.
        // We should have thrown otherwise.
        verify(success, typeof(this).stringof ~
               ".authenticate should have thrown on rejected authentication");
    }

    /***************************************************************************

        Returns:
            the name of the connected client or an empty string, if the
            connection has not been successfully established

    ***************************************************************************/

    public cstring connected_client ( )
    {
        return this.client_name;
    }

    /***************************************************************************

        Resets fields with data received from the client. Intended to be called
        when an established connection is shut down.

    ***************************************************************************/

    public void reset ( )
    {
        this.client_name.length = 0;
        assumeSafeAppend(this.client_name);
    }

    /***************************************************************************

        Validates the client timestamp. Does separate checks if it is in the
        range [1, time_t.max] for more detailed error reporting.

        Params:
            client_timestamp = client time stamp
            node_timestamp   = node time stamp

        Throws:
            `HmacAuthCode.RejectedException` if the client time stamp validation
            failed.

    ***************************************************************************/

    private void validateTimeStamp ( ulong client_timestamp, long node_timestamp )
    {
        debug ( SwarmConn )
            Stdout.formatln("SwarmConn: Client timestamp={}, Node timestamp={}",
                client_timestamp, node_timestamp);

        /*
         * Make sure casting client_timestamp to a signed integer will not
         * sign-overflow.
         */
        enforce(
            this.e_auth_rejected.set("Client timestamp above time_t.max"),
            client_timestamp <= time_t.max
        );

        enforce(
            this.e_auth_rejected.set("Zero client timestamp"),
            client_timestamp
        );

        static assert(is(time_t == long));
        /*
         * At this point we know for sure cast(time_t)client_timestamp cannot
         * sign-overflow so we can safely calculate the absolute difference.
         */
        enforce(
            this.e_auth_rejected
                .set("Client/node timestamp difference > 30 minutes"),
            abs(cast(time_t)client_timestamp - node_timestamp) <= 30 * 60
        );
    }
}
