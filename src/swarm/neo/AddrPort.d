/*******************************************************************************

    IP address (v4) and port pair.

    copyright:
        Copyright (c) 2016-2017 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.neo.AddrPort;

import core.sys.posix.netinet.in_; // in_addr, in_addr_t, in_port_t, socklen_t, sockaddr_in, AF_INET

import ocean.transition;
version ( UnitTest ) import ocean.core.Test;

extern (C) int inet_aton(Const!(char)* src, in_addr* dst);

/// ditto
public struct AddrPort
{
    import core.sys.posix.arpa.inet: ntohl, ntohs, htonl, htons, inet_ntop;
    import core.stdc.string: strlen;

    import swarm.Const : NodeItem;

    import ocean.util.container.map.model.StandardHash;
    import ocean.core.Test;
    import swarm.util.Verify;

    /// Minimum length required for an address format buffer.
    public enum AddrBufLength = INET6_ADDRSTRLEN;

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

    /***************************************************************************

        Converts the address of this instance to a string in the the well-known
        IPv4 dotted-decimal notation such as "192.168.2.111". The result is
        written to `dst` as a NUL-terminated string.
        `dst.length` needs to be at least `INET_ADDRSTRLEN` (from
        `core.sys.posix.netinet.in_`), for example by using a
        `char[INET_ADDRSTRLEN]` fixed-size array.

        To allocate a new buffer for the address, use
        ---
            AddrPort ap;
            mstring str = ap.getAddress(new char[INET_ADDRSTRLEN]);
        ---

        Params:
            dst = destination string; the minimum required length is
                `INET_ADDRSTRLEN`

        Returns:
            a slice referencing the result in `dst` (excluding the terminating
            NUL byte).

    ***************************************************************************/

    public mstring getAddress ( mstring dst )
    {
        verify(dst.length >= INET_ADDRSTRLEN,
            "dst.length expected to be at least INET_ADDRSTRLEN");
        auto src = in_addr(this.naddress);
        inet_ntop(AF_INET, &src, dst.ptr, cast(socklen_t)dst.length);
        // The only possible errors for inet_ntop  are a wrong address family
        // and `dst.length < INET_ADDRSTRLEN`. Neither can be the case here.
        return dst[0 .. strlen(dst.ptr)];
    }

    unittest
    {
        typeof(this) x;
        test(x.setAddress("192.168.222.111"));
        test!("==")(x.address_bytes, [cast(ubyte)192, 168, 222, 111]);

        char[INET_ADDRSTRLEN] buf;
        test!("==")(x.getAddress(buf), "192.168.222.111");

        test(!x.setAddress("192.168.333.111"));
        test(!x.setAddress("Die Katze tritt die Treppe krumm.")); // too long
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

    public sockaddr_in opCast ( ) // const
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

    public typeof(&this) set ( sockaddr_in src )
    {
        this.naddress = src.sin_addr.s_addr;
        this.nport    = src.sin_port;
        return &this;
    }

    /***************************************************************************

        Sets the address and port of this instance to those in node_item.

        Params:
            node_item = the input address and port

        Returns:
            this instance

    ***************************************************************************/

    public typeof(&this) set ( NodeItem node_item )
    {
        this.port = node_item.Port;
        this.setAddress(node_item.Address);
        return &this;
    }

    /***************************************************************************

        Gets the address and port of this instance in the format of a NodeItem.

        Params:
            buf = buffer used to format the address. Must be at least
                AddrBufLength bytes long

        Returns:
            NodeItem instance

    ***************************************************************************/

    public NodeItem asNodeItem ( ref mstring buf )
    {
        return NodeItem(this.getAddress(buf), this.port);
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
