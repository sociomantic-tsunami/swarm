/*******************************************************************************

    IP address (v4).

    copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.IPAddress;

import core.sys.posix.netinet.in_; // in_addr, in_addr_t, in_port_t, sockaddr_in, AF_INET

import ocean.transition;

extern (C) int inet_aton(Const!(char)* src, in_addr* dst);

public struct IPAddress
{
    import core.sys.posix.arpa.inet: ntohl, ntohs, htonl, htons;

    import ocean.util.container.map.model.StandardHash;

    /***************************************************************************

        Node address & port in network byte order, like they are stored in POSIX
        sockaddr_in. Network byte order means that `&naddress`/`&nport` point
        to the most significant byte (big endian).

    ***************************************************************************/

    public uint naddress = 0;
    static assert(is(in_addr_t == uint));

    public ushort nport = 0;
    static assert(is(in_port_t == ushort));

    /***************************************************************************

        Returns:
            true if the node address and port are set, i.e. not 0, or false if
            they are 0 (the initial value).

    ***************************************************************************/

    public bool is_set ( ) // const
    {
        return this.naddress && this.nport;
    }

    /***************************************************************************

        Returns:
            the address integer value in the native byte order of this platform,
            i.e. `address & 0xFF` is the least significant byte.

    ***************************************************************************/

    public uint address ( )
    {
        return ntohl(this.naddress);
    }

    /***************************************************************************

        Sets the address of this instance to address.

        Params:
            address = the input address in the native byte order of this
                      platform

        Returns:
            address

    ***************************************************************************/

    public uint address ( uint address )
    {
        this.naddress = htonl(address);
        return address;
    }


    /***************************************************************************

        Sets the address of this instance to `address`. For `address` the well-
        known IPv4 dotted-decimal notation such as "192.168.2.111" is supported,
        but others, too.

        This method uses the `inet_aton` glibc function. Refer to its manual
        page for further supported address notations.

        Params:
            address = the input address string

        Returns:
            true on success or false if `address` is invalid. If returning false
            then this instance was not modified.

    ***************************************************************************/

    public bool setAddress ( cstring address )
    {
        if (address.length > 19)
            return false;

        char[20] buf = '\0';
        buf[0 .. address.length] = address;

        in_addr result;

        if (inet_aton(buf.ptr, &result))
        {
            this.naddress = result.s_addr;
            return true;
        }

        return false;
    }

    unittest
    {
        typeof(*this) x;
        bool success = x.setAddress("192.168.222.111");
        assert(success);
        assert(x.address_bytes == [cast(ubyte)192, 168, 222, 111]);
        success = x.setAddress("192.168.333.111");
        assert(!success);
        success = x.setAddress("Die Katze tritt die Treppe krumm."); // too long
        assert(!success);
    }

    /***************************************************************************

        Returns:
            the port in the native byte order of this platform,
            i.e. `port & 0xFF` is the least significant byte.

    ***************************************************************************/

    public ushort port ( ) // const
    {
        return ntohs(this.nport);
    }

    /***************************************************************************

        Sets the port of this instance to port.

        Params:
            port = the input port in the native byte order of this platform

        Returns:
            port

    ***************************************************************************/

    public ushort port ( ushort port )
    {
        return this.nport = htons(port);
    }

    /***************************************************************************

        Returns a slice to the byte sequence of the address of this instance.

        Because the address is in network byte order (big endian), element0 of
        the returned array is the most significant byte. This is useful for
        formatting and populating the address from single bytes:
        ---
            Node node;
            // set to 192.168.47.11
            node.address = 0xC0_A8_2F_0B;
            Stdout.formatln("{}", node.address_bytes);
            // prints "[192, 168, 47, 11]"
            // set to 10.0.0.123
            node.address_bytes[] = [cast(ubyte)10, 0, 0, 123];
        ---

        Returns:
            a slice to the byte sequence of the address of this instance.

    ***************************************************************************/

    public ubyte[] address_bytes ( )
    {
        return (cast(ubyte*)&this.naddress)[0 .. this.naddress.sizeof];
    }

     /***************************************************************************

        Composes a sockaddr_in address with the address and port of this
        instance.

        Returns:
            the resulting sockaddr_in address.

    ***************************************************************************/

    sockaddr_in opCast ( ) // const
    {
        sockaddr_in result;
        result.sin_family      = AF_INET;
        result.sin_port        = this.nport;
        result.sin_addr.s_addr = this.naddress;
        return result;
    }

   /***************************************************************************

        Sets the address and port of this instance to those in src.

        Params:
            src = the input address and port

        Returns:
            this instance

    ***************************************************************************/

    public typeof(this) set ( sockaddr_in src )
    {
        this.naddress = src.sin_addr.s_addr;
        this.nport    = src.sin_port;
        return this;
    }

    /***************************************************************************

        Returns:
            the hash of this instance (for associative array compatibility)

    ***************************************************************************/

    version (none) public hash_t toHash ( ) // const
    {
        with (StandardHash)
        {
            return fnv1aT(this.nport, fnv1aT(this.naddress));
        }
    }

    /***************************************************************************

        opEquals for associative array compatibility.

    ***************************************************************************/

    version (none) public int opEquals ( IPAddress* node ) // const
    {
        return *this == *node;
    }


    /***************************************************************************

        opEquals for associative array compatibility.

    ***************************************************************************/

    version (none) public int opEquals ( ref IPAddress node ) // const
    {
        return *this == node;
    }

    /***************************************************************************

        Packs the address and port of this instance in a long value: Bits
        0 .. 15 (the least significant bits) contain the port and bits 16 .. 47
        the address, both in in the native byte order of this platform.
        This number is
          - unique for each address/port combination (no collisions),
          - always positive,
          - suitable for defining a sort order, the nodes will be sorted first
            by address, then by port,
          - not suitable to be used as a pseudorandom hash.

        Returns:
             the address and port of this instance in a long value, in in the
             native byte order of this platform.

    ***************************************************************************/

    public long cmp_id ( ) // const
    {
        /*
         * Make sure address & port really fit in a long without a signed
         * overflow.
         */
        static assert(this.address.sizeof + this.port.sizeof < long.sizeof);
        return ((cast(long)this.address) << (this.port.sizeof * 8)) | this.port;
    }
}
