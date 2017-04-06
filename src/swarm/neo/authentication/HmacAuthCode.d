/*******************************************************************************

    Helper class for HMAC-based authentication. Does not do GC allocation.

    Note: The terms "hash function" and "message digest" are used
    interchangeably in the context of HMAC and this class.

    TODO: It would be nice to have a constant length for authentication keys so
    that a key can be held in a static array, avoiding buffer allocation and
    referencing. HMAC internally pads or shortens the key to the block size of
    the hash function anyway so forcing the key length to match that block size
    is IMHO (David) a good idea.
    AFAICS cryptography libraries such as Gcrypt/GPG or Tango unfortunately
    provide a very generic API with little to no information about the block
    size of the hash functions they implement. However, the block size of a hash
    function is a constant that should (does?) not depend on a particular
    implementation.

    copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.authentication.HmacAuthCode;

/******************************************************************************/

struct HmacAuthCode
{
    import swarm.neo.authentication.HmacDef: Key, Code, Nonce;

    import ocean.util.cipher.gcrypt.HMAC;
    import ocean.util.cipher.gcrypt.c.gpgerror;
    import ocean.util.cipher.gcrypt.c.md;
    import ocean.util.cipher.gcrypt.c.random;

    import core.stdc.time: time_t;

    import ocean.transition;

    debug import ocean.io.Stdout;

    static:

    /***************************************************************************

        The hash/message digest algorithm used.

    ***************************************************************************/

    const hash_algoritm = gcry_md_algos.GCRY_MD_SHA512;

    private HMAC hmac;

    /***************************************************************************

        Creates an HMAC code from the provided timestamp, nonce and
        authorisation key (password). The provided timestamp and nonce are
        combined by string concatenation `timestamp_data ~ nonce`, where
        `timestamp_data` is the raw data of the timestamp, and hashed with the
        key.

        Params:
            auth_key = authorisation key (password) to use for encryption
            timestamp = timestamp to encrypt
            nonce = nonce to encrypt

    ***************************************************************************/

    public Code createHmac ( in ubyte[] auth_key, ulong timestamp, in ubyte[] nonce )
    in
    {
        assert(auth_key.length == Key.length,
               "auth_key.length not " ~ Key.length.stringof);
        assert(nonce.length == Nonce.length,
               "nonce.length not " ~ Nonce.length.stringof);
    }
    body
    {
        Code code;
        code.content[] = hmac.calculate(auth_key,
            (cast(ubyte*)(&timestamp))[0..timestamp.sizeof], nonce);
        return code;
    }

    /***************************************************************************

        D2: Return ubyte[nonce.length]

        Returns:
            a nonce (one use random number)

    ***************************************************************************/

    public Nonce createNonce ( )
    {
        Nonce nonce;
        gcry_create_nonce(nonce.content.ptr, nonce.content.length);
        return nonce;
    }

    /***************************************************************************

        Creates the libcgrypt HMAC object or terminates the application if it
        fails.

    ***************************************************************************/

    import cstdio = core.stdc.stdio: fprintf, stderr;
    import core.stdc.stdlib: exit, EXIT_FAILURE;

    version (D_Version2)
        mixin("shared static this ( ) { staticCtor(); }");
    else
        static this ( ) { staticCtor(); }

    // static ctor body separated out due to different ctor def in D1 vs D2
    private static void staticCtor ( )
    {
        try
        {
            /*
             * The `HMAC` constructor throws if the run-time libgcrypt doesn't
             * support the hash algorithm or or is used wrongly.
             */
            hmac = new HMAC(hash_algoritm);

            ubyte[Nonce.length] nonce;
            nonce[0] = 123;
            ubyte[Key.length] key;
            key[0 .. 3] = [0xCA, 0xFF, 0xE3];

            /*
             * This is a run-time test. If `createHmac()` succeeds this time
             * then it will always succeed.
             */
            createHmac(key, 456, nonce);
        }
        catch (GCryptError e)
        {
            cstdio.fprintf(cstdio.stderr, "libgcrypt test for SHA512 failed: %.*s @%s:%u\n".ptr,
                    e.msg.length, e.msg.ptr, e.file.ptr, e.line);
            exit(EXIT_FAILURE);
        }
    }

    /***************************************************************************

        Confirms the validity of the provided HMAC code by re-generating it from
        the provided timestamp, nonce and authorisation key (password). The new
        HMAC code should match the provided code.

        Params:
            auth_key = authorisation key (password) to use for encryption
            timestamp = timestamp to encrypt
            nonce = nonce to encrypt
            encoded = HMAC code to confirm

        Returns:
            true if the code was confirmed (the two HMAC codes matched)

    ***************************************************************************/

    public bool confirm ( in ubyte[] auth_key, ulong timestamp,
                          in ubyte[] nonce, in ubyte[] client_code )
    in
    {
        assert(auth_key.length    == Key.length,
               "auth_key.length not " ~ Key.length.stringof);
        assert(nonce.length       == Nonce.length,
               "nonce.length not " ~ Nonce.length.stringof);
        assert(client_code.length == Code.length,
               "client_code.length not " ~ Code.length.stringof);
    }
    body
    {
        auto reference = createHmac(auth_key, timestamp, nonce);

        debug ( SwarmConn ) Stdout.formatln("SwarmAuth: Confirm encoded={:X}",
            reference.content);

        return reference.content == client_code;
    }

    /***************************************************************************

        Exception to be thrown if the node rejected the authentication.

    ***************************************************************************/

    static class RejectedException: Exception
    {
        import ocean.core.Exception: ReusableExceptionImplementation;
        mixin ReusableExceptionImplementation!();
        import ocean.core.Array: copy;

        /***********************************************************************

            Authentication parameters: timestamp, nonce and client name, if
            available. For security reasons the key is not stored here.

        ***********************************************************************/

        ulong timestamp;

        Nonce nonce;

        char[] name;

        /***********************************************************************

            The HMAC used if available.

        ***********************************************************************/

        Code code;

        /**********************************************************************/

        this ( )
        {
            super("HMAC authentication rejected");
        }

        /***********************************************************************

            Sets the authentication parameters.

            Params:
                timestamp = client time stamp,
                nonce     = nonce
                name      = client name
                code      = the HMAC, if any

            In:
                nonce.length must be either Nonce.length or 0 if not available.
                code.length must be either Code.length or 0 if not available.

            Returns:
                this instance.

        ***********************************************************************/

        typeof(this) setAuthParams ( ulong timestamp, Const!(ubyte)[] nonce,
                                     Const!(char)[] name, Const!(ubyte)[] code = null )
        in
        {
            assert(nonce.length == Nonce.length || !nonce.length);
            assert(code.length  == Code.length  || !code.length);
        }
        body
        {
            this.timestamp = timestamp;

            if (nonce.length)
                this.nonce.content[] = nonce;
            else
               this.nonce.content[] = 0;

            if (code.length)
                this.code.content[] = code;
            else
               this.code.content[] = 0;

            this.name.copy(name);

            return this;
        }

        /***********************************************************************

            Resets the authentication parameters in this instance.

        ***********************************************************************/

        void resetAuthParams ( )
        {
            this.timestamp = this.timestamp.init;
            this.nonce.content[] = 0;
            this.code.content[] = 0;
            this.name.length = 0;
        }
    }

    /***************************************************************************

        Exception to be thrown if a GPG function fails.

        Does not need to be reusable because it can possibly be thrown only
        during startup.

    ***************************************************************************/

    static class GCryptError: Exception
    {
        import core.stdc.string: strlen;

        /***********************************************************************

            Constructor. Composes the message from funcname and the GCrypt
            error message according to gcry_error_code.

           Params:
                gcry_error_code = gcrypt error code
                funcname        = the name of the libcgrypt function that failed

        ***********************************************************************/

        this ( uint gcry_error_code, istring funcname,
               istring file = __FILE__, typeof(__LINE__) line = __LINE__ )
        {
            auto msg = "(no error description available)"[];

            if (auto msg0 = gpg_strerror(gcry_error_code))
            {
                msg = idup(msg0[0 .. strlen(msg0)]);
            }

            super(funcname ~ "() - " ~ msg, file, line);
        }
    }
}
