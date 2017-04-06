/*******************************************************************************

    Client utility class which owns a node connection socket and the associated
    socket exception.

    Copyright: Copyright (c) 2012-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.client.ClientSocket;

/******************************************************************************/

public class ClientSocket
{
    import swarm.neo.IPAddress;

    import ocean.sys.socket.AddressIPSocket;
    import ocean.io.select.protocol.generic.ErrnoIOException: SocketError;

    import core.sys.posix.netinet.in_: sockaddr_in;
    import core.stdc.errno: errno;

    import ocean.core.Enforce;

    debug ( ISelectClient ) import ocean.io.Stdout : Stderr;

    /***************************************************************************

        The socket which is used as the connection to the node.

    ***************************************************************************/

    private AddressIPSocket!() socket_;

    /***************************************************************************

        Socket error exception

    ***************************************************************************/

    private SocketError socket_error;

    /***************************************************************************

        Constructor.

        Params:
            node = the IPv4 address of the node

     **************************************************************************/

    public this ( )
    {
        this.socket_ = new AddressIPSocket!();
        this.socket_error = new SocketError(this.socket_);
    }

    /***************************************************************************

        Creates a non-blocking TCP/IPv4 socket (using socket()) with SIGPIPE
        suppressed, then calls connect() with the node address. The caller must
        check if connect() succeeded or failed and handle failure appropriately.
        Since the socket is non-blocking, connect() will very likely fail as
        follows:

            "If the connection cannot be established immediately and O_NONBLOCK
            is set for the file descriptor for the socket, connect() shall fail
            and set errno to [EINPROGRESS], but the connection request shall not
            be aborted, and the connection shall be established asynchronously.
            [...]
            When the connection has been established asynchronously, select()
            and poll() shall indicate that the file descriptor for the socket is
            ready for writing."

        Of course epoll() can be used instead of poll() here.

        The socket should not exist (-1 file descriptor).

        Returns:
            true if connect() succeeded or false if it failed.

        Throws:
            SocketError (IOException) if socket() failed. connect() is not
            called in this case.

    ***************************************************************************/

    public bool connect ( IPAddress node )
    {
        if (this.socket_.fd >= 0)
        {
            /*
             * TODO: Log a warning if this happens.
             * The socket should not exist or there is a bug. However, this
             * situation is too critical to assert or ignore it and leak file
             * descriptors.
             */
            this.socket.close();
        }

        this.socket_error.assertExSock(this.socket_.tcpSocket(true) >= 0,
                                       "error creating socket");
        this.socket_.close_in_destructor = false;
        return !this.socket_.connect(cast(sockaddr_in)node);
    }

    /***************************************************************************

        Returns:
            the socket.

    ***************************************************************************/

    public AddressIPSocket!() socket ( )
    {
        return this.socket_;
    }

    /***************************************************************************

        Returns:
            the socket exception associated with the socket.

    ***************************************************************************/

    public SocketError error ( )
    {
        return this.socket_error;
    }
}
