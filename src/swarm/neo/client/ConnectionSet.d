/*******************************************************************************

    Registry of the connections to the nodes.

    ConnectionSet also creates the RequestSet because the ConnectionSet and
    RequestSet constructors mutually depend on each other.

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

module swarm.neo.client.ConnectionSet;

import swarm.neo.client.RequestOnConn;

/// ditto
public final class ConnectionSet : RequestOnConn.IConnectionGetter
{
    import ocean.core.ExceptionDefinitions;
    import ocean.core.SmartUnion;

    import swarm.neo.client.Connection;
    import swarm.neo.client.RequestSet;
    import swarm.neo.client.NotifierTypes;
    import swarm.neo.IPAddress;
    import swarm.neo.authentication.Credentials;
    import ocean.io.select.EpollSelectDispatcher;

    import ocean.util.container.pool.ObjectPool;
    import ocean.util.container.pool.FreeList;

    import ocean.transition;

    debug ( SwarmConn ) import ocean.io.Stdout;

    /***************************************************************************

        Registry of connections.

    ***************************************************************************/

    private ConnectionRegistry!(Connection) connections;

    /***************************************************************************

        The request set.

    ***************************************************************************/

    private RequestSet request_set_;

    /***************************************************************************

        Connection pool.

    ***************************************************************************/

    private ObjectPool!(Connection) connection_pool;

    /***************************************************************************

        Pool of lists of connections. Used by
        ConnectionRegistry.iterateRoundRobin().

    ***************************************************************************/

    private FreeList!(Connection[]) connection_list_pool;

    /***************************************************************************

        Client authentication credentials, needed for the Connection
        constructor.

    ***************************************************************************/

    private Const!(Credentials) credentials;

    /***************************************************************************

        Epoll select dispatcher, needed for the Connection constructor.

    ***************************************************************************/

    private EpollSelectDispatcher epoll;

    /***************************************************************************

        The number of connections that were added with `start()` and are
        currently connecting to the node.

    ***************************************************************************/

    private uint n_nodes_starting = 0;

    /***************************************************************************

        Union of notifications about a connection.

    ***************************************************************************/

    private union ConnNotificationUnion
    {
        /// The connection has been successfully established.
        NodeInfo connected;

        /// An error (indicated by the `e` field) occurred while connecting. The
        /// connection attempt will automatically be retried.
        NodeExceptionInfo error_while_connecting;
    }

    /***************************************************************************

        Smart-union of notifications about a connection.

    ***************************************************************************/

    public alias SmartUnion!(ConnNotificationUnion) ConnNotification;

    /***************************************************************************

        User callback to be notified when a connection, which was added with
        `start()`,
           1. the connection was established, or
           2. detected an error -- for example, the node is unreachable or a
              socket I/O error, but also a failed protocol handshake or
              authentication -- and will try connecting again.

    ***************************************************************************/

    public alias void delegate ( ConnNotification info ) ConnectionNotifier;

    /// ditto
    private ConnectionNotifier conn_notifier;

    /***************************************************************************

        Constructor.

        When calling `start()` and a connection starts up, `conn_notifier`
        is called.

        Params:
            credentials       = client authentication credentials
            epoll             = epoll select dispatcher
            conn_notifier     = connection notifier callback

    ***************************************************************************/

    public this ( Const!(Credentials) credentials, EpollSelectDispatcher epoll,
                  ConnectionNotifier conn_notifier )
    {
        assert(conn_notifier !is null);

        this.epoll = epoll;
        this.credentials = credentials;
        this.connection_pool = new ObjectPool!(Connection);
        this.connection_list_pool = new FreeList!(Connection[]);
        this.request_set_ = new RequestSet(this, this.epoll);
        this.conn_notifier = conn_notifier;
    }

    /***************************************************************************

        Changes the connection notifier and returns the old notifier.

        Params:
            conn_notifier = connection notifier callback to use from now on

        Returns:
            previously set connection notifier

    ***************************************************************************/

    public ConnectionNotifier setConnectionNotifier (
        ConnectionNotifier conn_notifier )
    {
        auto old_conn_notifier = this.conn_notifier;
        this.conn_notifier = conn_notifier;
        return old_conn_notifier;
    }

    /***************************************************************************

        Returns:
            the number of registered nodes to which the client is in the state
            of establishing a connection *for the first time*

    ***************************************************************************/

    public size_t num_initializing_nodes ( )
    {
        return this.n_nodes_starting;
    }

    /***************************************************************************

        Returns:
            the number of registered nodes to which the client has an
            established connection

    ***************************************************************************/

    public size_t num_connected_nodes ( )
    {
        size_t num;
        foreach ( conn; this.connections )
        {
            if ( conn.status == conn.status.Connected )
                num++;
        }
        return num;
    }

    /***************************************************************************

        Returns:
            the request set.

    ***************************************************************************/

    public RequestSet request_set ( )
    {
        return this.request_set_;
    }

    /***************************************************************************

        Adds a connection to a node and starts it, if not already existing.

        Params:
            node_address = the address of the node to add and connect to, if not
                           already existing

        Returns:
            true if a connection for this node was added and started or false if
            one already existed.

    ***************************************************************************/

    public bool start ( IPAddress node_address )
    {
        bool added;
        auto connection = this.connections.put(node_address, added,
            this.connection_pool.get(new Connection(
                this.credentials, this.request_set_, this.epoll
            ))
        );

        if (added)
        {
            debug ( SwarmConn )
                Stdout.formatln("{}:{}: ConnectionSet.start() added",
                    node_address.address_bytes, node_address.port);

            this.n_nodes_starting++;
            connection.start(node_address, &this.notifyConnectResult);

            this.request_set_.newConnectionAdded(connection);
        }

        return added;
    }

    /***************************************************************************

        Shuts the connection to a node down and removes it from the registry, if
        found.

        Params:
            node_address = the address of the node to disconnect from and
                           remove, if existing

        Returns:
            true if the connection to the node was shut down and removed or
            false if not found.

    ***************************************************************************/

    public bool stop ( IPAddress node_address )
    {
        if (auto connection = node_address in this.connections)
        {
            connection.shutdownAndHalt();
            this.connections.remove(connection);
            this.connection_pool.recycle(connection);
            return true;
        }
        else
        {
            return false;
        }
    }

    /***************************************************************************

        Shuts the connection to all nodes down and clears the registry. All
        select clients owned by the connection set are unregistered from epoll.

    ***************************************************************************/

    public void stopAll ( istring file = __FILE__, typeof(__LINE__) line = __LINE__ )
    {
        for (auto conn = this.connections.getBoundary!(true)(); conn !is null;)
        {
            debug (SwarmConn)
            {
                auto address = conn.remote_address;
                Stdout.formatln("ConnectionSet: shutdown {}:{}",
                                address.address_bytes, address.port);
            }

            auto next = this.connections.getNext!(true)(conn);
            conn.shutdownAndHalt(file, line);
            this.connections.remove(conn);
            this.connection_pool.recycle(conn);
            conn = next;
        }
    }

    /***************************************************************************

        Gets the connection associated with the specified address.

        Params:
            node_address = the address of the node to get the connection for

        Returns:
            the corresponding Connection or null if the node is not registered

    ***************************************************************************/

    public Connection get ( IPAddress node_address )
    {
        return this.connections.get(node_address);
    }

    /***************************************************************************

        Iterates over available connections (i.e. whose `status` is
        `Connected`), starting with a different connection on each iteration.

        Params:
            dg = called for each connection iterating over; should return 0 to
                 continue or non-zero to stop the iteration

        Returns:
            0 if finished iterating over all nodes or the return value of `dg`
            if `dg` returned non-zero to stop the iteration.

    ***************************************************************************/

    public int iterateRoundRobin ( int delegate ( Connection conn ) dg )
    {
        auto connections_buf = this.connection_list_pool.get(
            new Connection[this.connection_pool.num_busy]);
        scope ( exit )
            this.connection_list_pool.recycle(connections_buf);

        return this.connections.iterateRoundRobin(connections_buf, dg);
    }

    /***************************************************************************

        Returns:
            the number of nodes registered (whether the connections are
            established or not)

    ***************************************************************************/

    public size_t length ( )
    {
        return this.connection_pool.num_busy;
    }

    /***************************************************************************

        `foreach` iteration over all connections in the set.

        Obtains the next node connection in the order of node addresses.

        Params:
            connection = the connection to get the next one for

        Returns:
            the next node connection or null if either the connection set is
            empty or `connection` is `null`.

    ***************************************************************************/

    public int opApply ( int delegate ( ref Connection conn ) dg )
    {
        return this.connections.opApply(dg);
    }

    /***************************************************************************

        `foreach_reverse` iteration over all connections in the set.

        Obtains the next node connection in the order of node addresses.

        Params:
            connection = the connection to get the next one for

        Returns:
            the next node connection or null if either the connection set is
            empty or `connection` is `null`.

    ***************************************************************************/

    public int opApplyReverse ( int delegate ( ref Connection conn ) dg )
    {
        return this.connections.opApplyReverse(dg);
    }

    /***************************************************************************

        Connection startup notification callback method. Decrements the counter
        of connections starting up, and calls the user notifier.

        Params:
            connection = the connection giving the startup notification
            e          = `null` if the connection finished starting up,
                          otherwise information about an error connecting; the
                          connection will retry connecting in this case

    ***************************************************************************/

    private void notifyConnectResult ( Connection connection,
        Exception e = null )
    {
        ConnNotification info;

        if (e is null)
        {
            this.n_nodes_starting--;
            info.connected = NodeInfo(connection.remote_address);
        }
        else
        {
            info.error_while_connecting =
                NodeExceptionInfo(connection.remote_address, e);
        }

        this.conn_notifier(info);
    }
}

/*******************************************************************************

    Connection registry data structure. The actual connection type is templated
    to allow for easy unittesting without making real socket connections.

    Params:
        C = the tree map value class or struct. (`MockConnection` in the unit
            test consists of the minimum required members of such a class or
            struct `C`.)

*******************************************************************************/

private struct ConnectionRegistry ( C )
{
    import ocean.transition;
    import Array = ocean.core.Array : shuffle;
    import core.sys.posix.stdlib : drand48;
    import swarm.neo.util.TreeMap;
    import swarm.neo.IPAddress;

    /***************************************************************************

        Defines the actual value type `Connection` to be either the class `C`
        or a pointer to the struct `C`.

    ***************************************************************************/

    static if (is(C == class))
    {
        alias C Elem;
    }
    else
    {
        static assert (is(C == struct));
        alias C* Elem;
    }

    /***************************************************************************

        Map of node addresses -> connections. Used for fast lookup and ordered
        iteration (by node address).

    ***************************************************************************/

    private TreeMap!(C.TreeMapElement) connection_map;

    /***************************************************************************

        Adds a connection to the registry.

        Params:
            node_address = the address of the node
            added = outputs true if a new node was added or false if node was
                already registered (in which case, the existing connection is
                returned)
            new_conn = a new connection instance to place in the set if adding,
                evaluated once if adding a new node

        Returns:
            the connection to the node or null if either not found or currently
            not connected.

    ***************************************************************************/

    public Elem put ( IPAddress node_address, out bool added,
        lazy Elem new_conn )
    {
        return this.connection_map.put(node_address.cmp_id, added, new_conn);
    }

    /***************************************************************************

        Obtains the connection to a node.

        Params:
            node_address = the address of the node to get the connection for

        Returns:
            the connection to the node or null if not found.

    ***************************************************************************/

    public Elem get ( IPAddress node_address )
    {
        return node_address.cmp_id in this.connection_map;
    }

    // ditto
    public alias get opIn_r;

    /***************************************************************************

        Removes the specified connection from the registry.

        Params:
            node_address = the address of the node to remove

    ***************************************************************************/

    public void remove ( Elem conn )
    {
        this.connection_map.remove(conn);
    }

    /***************************************************************************

        Obtains the first or last connection in the order of node addresses.

        Template_Params:
            first = `true`: get the first available connection
                    `false`: get the last available connection

        Returns:
            the connection to a node or null if no connection is available.

    ***************************************************************************/

    public Elem getBoundary ( bool first = true ) ( )
    {
        return this.connection_map.getBoundary!(first)();
    }

    /***************************************************************************

        Obtains the next connection in the order of node addresses.

        Params:
            connection = the connection to get the next one for

        Template_Params:
            ascend = `true`: look in ascending order
                     `false`: look in descending order

        Returns:
            the next connection or null if `connection` is either the last
            connection so there is no next one or `null`.

    ***************************************************************************/

    public Elem getNext ( bool ascend = true ) ( Elem connection )
    {
        if (connection !is null)
        {
            if (connection.treemap_backlink is null)
            {
                // conn.treemap_backlink is null if the connection is currently
                // not in the connection set, for example, if it has been
                // removed in the mean time since the caller obtained it. In
                // this case look a connection up by address.

                ulong address_id = connection.remote_address.cmp_id;

                if (auto conn_found =
                    this.connection_map.getThisOrNext!(ascend)(address_id)
                )
                {
                    // conn_found has the same or the next address as
                    // connection. If it is different (i.e. the next) return it,
                    // otherwise (i.e. the same address) return the next one.

                    static if (ascend)
                    {
                        if (conn_found.remote_address.cmp_id > address_id)
                            return conn_found;
                    }
                    else
                    {
                        if (conn_found.remote_address.cmp_id < address_id)
                            return conn_found;
                    }

                    return this.connection_map.iterate!(ascend)(conn_found);
                }
                else
                {
                    return null;
                }
            }
            else
            {
                return this.connection_map.iterate!(ascend)(connection);
            }
        }

        return null;
    }

    /***************************************************************************

        `foreach` iteration over all connections in the set.

        Obtains the next node connection in the order of node addresses.

        Params:
            connection = the connection to get the next one for

        Returns:
            the next node connection or null if either the connection set is
            empty or `connection` is `null`.

    ***************************************************************************/

    public int opApply ( int delegate ( ref Elem conn ) dg )
    {
        for (
            auto conn = this.connection_map.getBoundary!(true)();
            conn !is null;
            conn = this.getNext!(true)(conn)
        )
        {
            if (int x = dg(conn))
                return x;
        }

        return 0;
    }

    /***************************************************************************

        `foreach_reverse` iteration over all connections in the set.

        Obtains the next node connection in the order of node addresses.

        Params:
            connection = the connection to get the next one for

        Returns:
            the next node connection or null if either the connection set is
            empty or `connection` is `null`.

    ***************************************************************************/

    public int opApplyReverse ( int delegate ( ref Elem conn ) dg )
    {
        for (
            auto conn = this.connection_map.getBoundary!(false)();
            conn !is null;
            conn = this.getNext!(false)(conn)
        )
        {
            if (int x = dg(conn))
                return x;
        }

        return 0;
    }

    /***************************************************************************

        Iterates over available connections (i.e. whose `status` is
        `Connected`), starting with a different connection on each iteration and
        selecting subsequent connections in random order.

        Note: iterating over connections in random order ensures that all
        connections are favoured equally. Even choosing an initial connection at
        random and then iterating over the map in "normal" order can lead to an
        imbalance. For example, when one node is down, every time that node is
        selected as the first node, the following node (in normal order) will
        most likely handle the request successfully, leading to that node
        handling more requests than others.

        Params:
            connections_buf = buffer to store the list of shuffled connections.
                Required to iterate over the connections in a random but
                complete (i.e. not skipping any) order.
            dg = called for each connection iterating over; should return 0 to
                 continue or non-zero to stop the iteration

        Returns:
            0 if finished iterating over all nodes or the return value of `dg`
            if `dg` returned non-zero to stop the iteration.

    ***************************************************************************/

    public int iterateRoundRobin ( ref Elem[] connections_buf,
        int delegate ( Elem conn ) dg )
    {
        connections_buf.length = 0;
        enableStomping(connections_buf);

        this.opApply(
            ( ref Elem conn )
            {
                connections_buf ~= conn;
                return 0;
            }
        );

        if ( connections_buf.length == 0 )
            return 0;

        Array.shuffle(connections_buf, drand48());

        foreach ( conn; connections_buf )
        {
            if ( conn.status != conn.status.Connected )
                continue;

            if ( auto ret = dg(conn) )
                return ret;
        }

        return 0;
    }
}

/*******************************************************************************

    Unit Test

*******************************************************************************/

version (UnitTest)
{
    import swarm.neo.util.TreeMap;
    import swarm.neo.IPAddress;

    // Contains only the address, the ebtree node and the status.
    private struct MockConnection
    {
        import swarm.neo.client.Connection; // Connection.Status

        struct TreeMapElement
        {
            import ocean.util.container.ebtree.c.eb64tree;
            eb64_node ebnode;
            MockConnection* connection;

            alias connection user_element_with_treemap_backlink;
        }

        TreeMapElement* treemap_backlink = null;

        IPAddress remote_address;

        Connection.Status status = Connection.Status.Connected;
    }
}

unittest
{
    static void setAddress ( ref IPAddress address, ubyte[] address_bytes ... )
    in
    {
        assert(address_bytes.length == 4, "expected 4 address bytes");
    }
    body
    {
        address.address_bytes[] = address_bytes;
    }

    static IPAddress newAddress ( ushort port, ubyte[] address_bytes ... )
    {
        IPAddress address;
        setAddress(address, address_bytes);
        address.port = port;
        return address;
    }

    // Empty set ---------------------------------------------------------------

    ConnectionRegistry!(MockConnection) set;

    {
        assert(set.connection_map.is_empty);
        assert(set.get(IPAddress.init) is null);
        assert(set.getBoundary!(false)() is null);
        assert(set.getBoundary!(true)() is null);
        assert(set.getNext!(true)(null) is null); // getNext should accept null
        assert(set.getNext!(false)(null) is null);

        foreach (conn; set)
            assert(false);
    }

    // One connection: 127.0.0.1:4711 ------------------------------------------

    auto address1 = newAddress(4711, 127, 0, 0, 1);
    MockConnection* conn1;

    {
        bool added;
        conn1 = set.connection_map.put(address1.cmp_id, added, new MockConnection);
        conn1.remote_address = address1;
        assert(added);
        assert(!set.connection_map.is_empty);
        assert(set.get(address1) is conn1);

        {
            auto conn = set.getBoundary!(true);
            assert(conn is conn1);
            conn = set.getNext!(true)(conn);
            assert(conn is null);
        }
        {
            auto conn = set.getBoundary!(false);
            assert(conn is conn1);
            conn = set.getNext!(false)(conn);
            assert(conn is null);
        }

        {
            bool i = false;
            foreach (conn; set)
            {
                assert(!i);
                assert(conn is conn1);
                i = true;
            }
            assert(i);

            i = false;
        }
        {
            bool i = false;

            foreach_reverse (conn; set)
            {
                assert(!i);
                assert(conn is conn1);
                i = true;
            }
            assert(i);
        }

        // Attempt to add the same connection again, should not be added but the
        // existing connection be returned.

        assert(
            set.connection_map.put(
                address1.cmp_id, added,
                function MockConnection* ( ) {assert(false);}()
            ) is conn1
        );
        assert(!added);
        assert(!set.connection_map.is_empty);
        assert(set.get(address1) is conn1);

        assert(set.getBoundary!(false)() is conn1);
        assert(set.getBoundary!(true)() is conn1);
        assert(set.getNext!(false)(conn1) is null);
        assert(set.getNext!(true)(conn1) is null);
    }

    // Second connection: 127.0.0.1:4712 ---------------------------------------

     auto address2 = newAddress(4712, 127, 0, 0, 1);
     MockConnection* conn2;

    {
        bool added;
        conn2 = set.connection_map.put(address2.cmp_id, added, new MockConnection);
        conn2.remote_address = address2;
        assert(added);
        assert(set.get(address2) is conn2);

        {
            auto conn = set.getBoundary!(true);
            assert(conn is conn1);
            conn = set.getNext!(true)(conn);
            assert(conn is conn2);
            conn = set.getNext!(true)(conn);
            assert(conn is null);
        }
        {
            auto conn = set.getBoundary!(false);
            assert(conn is conn2);
            conn = set.getNext!(false)(conn);
            assert(conn is conn1);
            conn = set.getNext!(false)(conn);
            assert(conn is null);
        }

        {
            uint i = 0;
            foreach (conn; set)
            {
                switch (++i)
                {
                    case 1:
                        assert(conn is conn1);
                        break;
                    case 2:
                        assert(conn is conn2);
                        break;
                    default:
                        assert(false, "too many iterations");
                    case 0:
                        assert(false);
                }
            }
            assert(i == 2, "expected two iterations");
        }
        {
            uint i = 0;
            foreach_reverse (conn; set)
            {
                switch (++i)
                {
                    case 1:
                        assert(conn is conn2);
                        break;
                    case 2:
                        assert(conn is conn1);
                        break;
                    default:
                        assert(false, "too many iterations");
                    case 0:
                        assert(false);
                }
            }
            assert(i == 2, "expected two iterations");
        }
    }

    // Third connection: 127.0.0.2:4711 ----------------------------------------

    auto address3 = newAddress(4711, 127, 0, 0, 2);
    MockConnection* conn3;

    {
        bool added;
        conn3 = set.connection_map.put(address3.cmp_id, added, new MockConnection);
        conn3.remote_address = address3;
        assert(added);
        assert(set.get(address3) is conn3);

        {
            auto conn = set.getBoundary!(true);
            assert(conn is conn1);
            conn = set.getNext!(true)(conn);
            assert(conn is conn2);
            conn = set.getNext!(true)(conn);
            assert(conn is conn3);
            conn = set.getNext!(true)(conn);
            assert(conn is null);
        }
        {
            auto conn = set.getBoundary!(false);
            assert(conn is conn3);
            conn = set.getNext!(false)(conn);
            assert(conn is conn2);
            conn = set.getNext!(false)(conn);
            assert(conn is conn1);
            conn = set.getNext!(false)(conn);
            assert(conn is null);
        }

        {
            uint i = 0;
            foreach (conn; set)
            {
                switch (++i)
                {
                    case 1:
                        assert(conn is conn1);
                        break;
                    case 2:
                        assert(conn is conn2);
                        break;
                    case 3:
                        assert(conn is conn3);
                        break;
                    default:
                        assert(false, "too many iterations");
                    case 0:
                        assert(false);
                }
            }
            assert(i == 3, "expected three iterations");
        }
        {
            uint i = 0;
            foreach_reverse (conn; set)
            {
                switch (++i)
                {
                    case 1:
                        assert(conn is conn3);
                        break;
                    case 2:
                        assert(conn is conn2);
                        break;
                    case 3:
                        assert(conn is conn1);
                        break;
                    default:
                        assert(false, "too many iterations");
                    case 0:
                        assert(false);
                }
            }
            assert(i == 3, "expected three iterations");
        }
    }

    // Remove conn2 ------------------------------------------------------------

    {
        set.connection_map.remove(conn2);
        assert(set.get(conn2.remote_address) is null);

        {
            auto conn = set.getBoundary!(true);
            assert(conn is conn1);
            conn = set.getNext!(true)(conn);
            assert(conn is conn3);
            conn = set.getNext!(true)(conn);
            assert(conn is null);
        }
        {
            auto conn = set.getBoundary!(false);
            assert(conn is conn3);
            conn = set.getNext!(false)(conn);
            assert(conn is conn1);
            conn = set.getNext!(false)(conn);
            assert(conn is null);
        }

        {
            uint i = 0;
            foreach (conn; set)
            {
                switch (++i)
                {
                    case 1:
                        assert(conn is conn1);
                        break;
                    case 2:
                        assert(conn is conn3);
                        break;
                    default:
                        assert(false, "too many iterations");
                    case 0:
                        assert(false);
                }
            }
            assert(i == 2, "expected two iterations");
        }
        {
            uint i = 0;
            foreach_reverse (conn; set)
            {
                switch (++i)
                {
                    case 1:
                        assert(conn is conn3);
                        break;
                    case 2:
                        assert(conn is conn1);
                        break;
                    default:
                        assert(false, "too many iterations");
                    case 0:
                        assert(false);
                }
            }
            assert(i == 2, "expected two iterations");
        }

        // Test getNext() with conn2, which is not in the set, ...

        assert(conn2.treemap_backlink is null);

        // ... still getNext() should be able to find the next element by
        // looking it up using conn2.remote_address.

        assert(set.getNext!(true)(conn2) is conn3);
        assert(set.getNext!(false)(conn2) is conn1);

        // Get the next connection from conn2 where conn2.remote_address is the
        // same as the address of an element in the set, to test if getNext()
        // handles this case properly.
        conn2.remote_address = conn1.remote_address;
        assert(set.getNext!(true)(conn2) is conn3);
        assert(set.getNext!(false)(conn2) is null);

        conn2.remote_address = conn3.remote_address;
        assert(set.getNext!(true)(conn2) is null);
        assert(set.getNext!(false)(conn2) is conn1);
    }
}
