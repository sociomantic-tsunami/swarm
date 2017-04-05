/*******************************************************************************

    Functions for converting between strings, hash strings, hash values, etc.

    The basic types which are dealt with are:

        * hash_t - 32/64-bit unsigned integer hash values.

        * HashStr - Hexadecimal hash strings - a typedef of char[], with methods
          for checking validity. This typedef is defined so that we can have
          typesafe hashes which can be differentiated from normal char[]s
          (representing unhashed keys). Valid hex hash strings have the
          following properties, which are checked by functions accepting them:
              - Only characters 0..9 and a..f allowed (upper case is invalid)
              - Exactly as many characters as hex digits are required to represent
                the hash value range (ie 8 characters for a 32 bit hash).

        * char[] - Normal strings - may be either key values or hashes stored in
          char arrays. The former can be converted to a HashStr by applying a
          hashing algorithm (see ocean.io.digest.Fnv1). The latter can be
          converted to a HashStr simply by checking their validity and then
          casting. Note that in this case, upper case hex digits are converted
          to lower case.

        * time_t - Unix timestamps - if time_t is the same size as the hash_t
          type, timestamps can be converted to hash values simply by casting.

    TODO: This module would probably be better placed in ocean, as it's not just
    the swarm nodes/clients which need to convert hashes between various
    formats. There are also several generally useful functions here, like isHex,
    hexToLower and intToHex.

    copyright:      Copyright (c) 2014-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.util.Hash;



/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.transition;

import ocean.core.Array;

import ocean.io.digest.Fnv1;

import ocean.math.Range;

import ocean.core.BitManip : bitswap;

import core.stdc.time: time_t;

import core.stdc.string: memmove;

import Integer = ocean.text.convert.Integer_tango;



/*******************************************************************************

    HashRange alias for template in ocean.math.Range

*******************************************************************************/

public alias Range!(hash_t) HashRange;

/***************************************************************************

    Alias for hexadecimal digest static string

 **************************************************************************/

public alias Fnv1a.HexDigest HexDigest;

/***************************************************************************

    Constant telling the number of hex digits (chars) in a valid
    hash string

***************************************************************************/

public const HashDigits = Fnv1a.HEXDGT_LENGTH;

/***************************************************************************

    Converts a hash_t into a hash_t (no-op).

    This is just a convenience method enabling other code to just
    call toHash for parameters of any type, including hash_t.

    Params:
        hash = hash value

    Returns:
        hash, without any conversion

 **************************************************************************/

public hash_t toHash ( hash_t hash )
{
    return hash;
}


/***************************************************************************

    Gets the numerical value of a hex hash digest string.

    Params:
        hash = hash to convert

    Returns:
        hash value of the specified hash digest

 **************************************************************************/

public hash_t toHash ( cstring hash )
{
    return straightToHash(hash);
}


/***************************************************************************

    Creates a hash value for a timestamp.

    Params:
        time = timestamp to convert

    Returns:
        a hash value corresponding to the passed time

 **************************************************************************/

public hash_t toHash ( time_t time )
{
    static assert(time_t.sizeof == hash_t.sizeof,
        "timeToHash - cannot automatically convert from time_t to hash_t - types are of different sizes");

    return cast(hash_t) time;
}


/***************************************************************************

    Converts a hash_t[] into a hash_t[] (just a copy - no conversion).

    This is just a convenience method enabling other code to just call
    toHash for parameters of any type, including hash_t[].

    Params:
        hashes = list of hash value

    Returns:
        hashes, without any conversion

 **************************************************************************/

public hash_t[] toHash ( hash_t[] hashes, ref hash_t[] out_hashes )
{
    out_hashes.copy(hashes);

    return out_hashes;
}


/***************************************************************************

    Creates a hash value from a hash value, without running it through the
    hashing algorithm (no-op).

    This is just a convenience method enabling other code to just call
    toHash for parameters of any type, including hash_t.

    Params:
        hash = hash value

    Returns:
        hash, without any conversion

 **************************************************************************/

public hash_t straightToHash ( hash_t hash )
{
    return hash;
}


/***************************************************************************

    Creates a hash value from a valid hash string, without running it
    through the hashing algorithm

    Params:
        hash = hash string to convert

    Returns:
        hash value of the string

    Throws:
        asserts that the string is a valid hex hash

 **************************************************************************/

public hash_t straightToHash ( cstring hash )
in
{
    assert(isHash(hash), "straightToHash(cstring)  - string is not a valid hash " ~ hash);
}
body
{
    return cast(hash_t) Integer.toLong(hash, 16);
}


/***************************************************************************

    Creates a hex value from a list of valid hash strings, without running
    them through the hashing algorithm

    Params:
        hash_strings = list of hash strings to convert
        hashes = output list of hashes

    Returns:
        list of converted hashes

 **************************************************************************/

public hash_t[] straightToHash ( cstring[] hash_strings, ref hash_t[] hashes )
{
    enableStomping(hashes);
    hashes.length = hash_strings.length;
    enableStomping(hashes);
    foreach ( i, hash; hash_strings )
    {
        hashes[i] = straightToHash(hash);
    }

    return hashes;
}


/***************************************************************************

    Converts a hash value into a string.

    Params:
        val = value to convert

    Returns:
        string containing the hex hash for the specified value

    Throws:
        asserts that the resulting string is a valid hex hash

 **************************************************************************/

public mstring toHexString ( hash_t val, mstring hash )
in
{
    assert(hash.length >= HexDigest.length,
           "'hash' must have a length >= HexDigest.length");
}
out ( result )
{
    assert(isHash(result),
           "Resulting hash string isn't valid - " ~ result);
}
body
{
    return intToHex(val, hash);
}


/***************************************************************************

    Converts a hash value into a timestamp.

    Params:
        hash = hash value to convert

    Returns:
        timestamp corresponding to the specified hash

 **************************************************************************/

public time_t toTime ( hash_t hash )
{
    static assert(time_t.sizeof == hash_t.sizeof,
        "hashToTime - cannot automatically convert from time_t to hash_t - types are of different sizes");

    return cast(time_t) hash;
}


/***************************************************************************

    Tells whether the given hash is within the responsibility of a server node
    with the given minimum and maximum hash range.

    Note that, for the purposes of this check, the hash is reversed, such
    that the least significant bits become the most significant and vice
    versa. This bit-reversal is performed in order to transparently handle
    the case where the record keys used are sequential integers which would
    otherwise be sent sequentially to the set of nodes, rather than
    being distributed evenly among them. A server may, for example, use
    timestamps as record keys, so would require this bit-reversal.

    FIXME: The bit-reversal procedure is now regarded as something of a hack
    and will ideally be removed in the future.

    Params:
        hash = hash to check responsibility for
        min = minimum hash for which node is responsible
        max = maximum hash for which node is responsible

    Returns:
        true if responsible or false otherwise

***************************************************************************/

public bool isWithinNodeResponsibility ( hash_t hash, hash_t min, hash_t max )
{
    hash = bitswap(hash);

    return min <= hash && hash <= max;
}

unittest
{
    const hash_t min = 0b0000000000000000000000000000000000000000000000000000000000000010;
    const hash_t max = 0b0000000000000000000000000000000000000000000000000000000000010000;
    hash_t hash;

    // Maximum
    hash = 0b0000100000000000000000000000000000000000000000000000000000000000;
    assert(isWithinNodeResponsibility(hash, min, max));

    // Minimum
    hash = 0b0100000000000000000000000000000000000000000000000000000000000000;
    assert(isWithinNodeResponsibility(hash, min, max));

    // Too low
    hash = 0b1000000000000000000000000000000000000000000000000000000000000000;
    assert(!isWithinNodeResponsibility(hash, min, max));

    // Too high
    hash = 0b0000010000000000000000000000000000000000000000000000000000000000;
    assert(!isWithinNodeResponsibility(hash, min, max));
}


/***************************************************************************

    Checks whether a string is a valid hex hash. To be valid it must:
        1. have the correct number of digits (as defined by the hash_t type).
        2. contain only hex digits (0..f)

    Params:
        str = string to check

    Returns:
        true if the string is a valid hex hash, false otherwise

 **************************************************************************/

public bool isHash ( cstring str )
{
    return str.length == HashDigits && isHex(str);
}


/***************************************************************************

    Checks whether a string contains only valid hexadecimal digits.

    Note: this function will *not* pass a string which begins with "0x"

    Params:
        str = string to check
        allow_upper_case = flag to allow  / disallow upper case characters

    Returns:
        true if the string is a valid hex number, false otherwise

 **************************************************************************/

public bool isHex ( cstring str, bool allow_upper_case = true )
{
    foreach ( c; str )
    {
        if ( !isHex(c, allow_upper_case ) )
        {
            return false;
        }
    }
    return true;
}


/***************************************************************************

    Checks whether a character is a valid hexadecimal digit.

    Params:
        c = character to check
        allow_upper_case = flag to allow  / disallow upper case characters

    Returns:
        true if the character is a valid hex digit, false otherwise

 **************************************************************************/

public bool isHex ( char c, bool allow_upper_case = true )
{
    return (c >= '0' && c <= '9')
        || (c >= 'a' && c <= 'f')
        || ((c >= 'A' && c <= 'F') && allow_upper_case);
}


/***************************************************************************

    Converts any characters in the range A..F in a hex string to lower case
    (a..f).

    Params:
        str = string to convert

    Returns:
        converted string

 **************************************************************************/

public mstring hexToLower ( mstring str )
{
    foreach ( ref c; str )
    {
        if ( c >= 'A' && c <= 'F' )
        {
            c -= ('A' - 'a');
        }
    }

    return str;
}


/***************************************************************************

    Creates a hexadecimal string from an integer. A number of hex digits
    equal to the string's length are converted.

    Params:
        val = value to convert
        hash = destination string; must be initially set to the length

    Returns:
        string containing the converted hex digits

***************************************************************************/

public mstring intToHex ( hash_t val, mstring hash )
{
    foreach_reverse ( ref h; hash )
    {
        h = "0123456789abcdef"[val & 0xF];
        val >>= 4;
    }
    return hash;
}


/***************************************************************************

    Evaluates to true if T is a type that can be used as key or to false
    otherwise

 **************************************************************************/

public template isKeyType ( T )
{
    const isKeyType = is (T == hash_t)    ||
                      is (T == HexDigest) ||
                      is (T == time_t)    ||
                      is (Unqual!(T[0]) == char);
}



/*******************************************************************************

    Unit test

*******************************************************************************/

version ( UnitTest )
{
    import ocean.math.random.Random;

    private class HashGenerator
    {
        protected static Random random;

        static this()
        {
            HashGenerator.random = new Random();
        }

        public static void randomizeLength ( ref mstring str )
        {
            ubyte b;
            HashGenerator.random(b);
            enableStomping(str);
            str.length = b%32;
            enableStomping(str);
        }

        public static mstring str ( ref mstring str, bool rand_len = true )
        {
            if ( rand_len )
            {
                HashGenerator.randomizeLength(str);
            }

            foreach ( ref c; str )
            {
                HashGenerator.random(c);
            }

            return str;
        }

        public static mstring nonHexStr ( ref mstring str, bool rand_len = true )
        {
            if ( rand_len )
            {
                HashGenerator.randomizeLength(str);
            }

            foreach ( ref c; str )
            {
                do
                {
                    HashGenerator.random(c);
                } while (isHex(c));
            }

            return str;
        }

        public static mstring hexStr ( ref mstring str, bool rand_len = true )
        {
            if ( rand_len )
            {
                HashGenerator.randomizeLength(str);
            }

            foreach ( ref c; str )
            {
                ubyte b;
                HashGenerator.random(b);
                b %= 16;
                c = cast(char)(( b < 10 ) ? ('0' + b) : ('a' + (b - 10)));
            }

            return str;
        }

        public static mstring hashStr ( ref mstring str )
        {
            enableStomping(str);
            str.length = HashDigits;
            enableStomping(str);
            HashGenerator.hexStr(str, false);

            return str;
        }
    }
}

unittest
{
    const Iterations = 10_000;
    mstring str;
    cstring cstr;

    // Test validation of some random hex values
    for ( uint i = 0; i < Iterations; i++ )
    {
        HashGenerator.hexStr(str);
        assert(isHex(str), "swarm.Hash unittest - error in isHex, " ~ str ~ " is invalid");
    }

    str.length = 16;
    // Test validation of some random hex values
    for ( ulong i = ulong.max - 1; i > ulong.max/10_000*2; i-=ulong.max/10_000 )
    {
        cstr = Integer.format(str, i, "x16");

        assert(straightToHash(cstr) == i, "swarm.Hash unittest - error in straightToHash, " ~ str ~ " is invalid");
    }

    // Test validation of some random non-hex values
    for ( uint i = 0; i < Iterations; i++ )
    {
        HashGenerator.nonHexStr(str);
        assert(str.length == 0 || !isHex(str), "swarm.Hash unittest - error in isHex, " ~ str ~ " should be invalid");
    }

    // Test validation of some random hashes
    for ( uint i = 0; i < Iterations; i++ )
    {
        HashGenerator.hashStr(str);
        assert(isHash(str), "swarm.Hash unittest - error in isHash, " ~ str ~ " is invalid");
    }

    // Test validation of some random invalid length hashes
    for ( uint i = 0; i < Iterations; i++ )
    {
        do
        {
            HashGenerator.hexStr(str);
        } while ( str.length == HashDigits );
        assert(!isHash(str), "swarm.Hash unittest - error in isHash, " ~ str ~ " should be invalid");
    }

    // Test validation of some random non-hashes
    for ( uint i = 0; i < Iterations; i++ )
    {
        HashGenerator.nonHexStr(str);
        assert(!isHash(str), "swarm.Hash unittest - error in isHash, " ~ str ~ " should be invalid");
    }
}
