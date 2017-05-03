/*******************************************************************************

    Definition of the lengths and types of the authentication key, code and
    nonce.

    copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.authentication.HmacDef;

public const key_length = 1024 / 8;
public const code_length = 512 / 8;
public const nonce_length = 32 / 8;


/* TODO: in D2, we could simply use fixed-length arrays, as follows:
version (D_Version2)
{
    alias ubyte[key_length]    Key;
    alias ubyte[code_length]     Code;
    alias ubyte[nonce_length] Nonce;
}
*/

/***************************************************************************

    In D1 wrap a static array in a struct to work around the lack of
    assigning to and returning a static array.

***************************************************************************/

struct StaticArray ( T, size_t n )
{
    const length = n;

    T[n] content;
}

/***************************************************************************

    Type definition of an authentication key. It is a 1024-bit sequence, the
    block length of the hash function used, SHA-512. This is because HMAC
    would reduce or extend the length of the key to the hash function block
    length anyway, shorter keys are "strongly discouraged" [RFC2104], and a
    static array avoids the hassle of needing reusable GC allocated buffers.

    Standards:
        HMAC specification
            https://tools.ietf.org/html/rfc2104#section-3

        SHA512 specification
            http://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.180-4.pdf

***************************************************************************/

alias StaticArray!(ubyte, key_length) Key;

/***************************************************************************

    Type definition of the authentication code, a 512-bit sequence for the
    hash function used, SHA-512.

***************************************************************************/

alias StaticArray!(ubyte, code_length) Code;

/***************************************************************************

    Type definition of the nonce, a 32-bit sequence. The nonce is actually a
    part of the Swarm authentication protocol, not of HMAC itself, so it is
    independent from the hash function used.

***************************************************************************/

alias StaticArray!(ubyte, nonce_length) Nonce;
