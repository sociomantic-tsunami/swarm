/*******************************************************************************

    Client credentials

    copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.authentication.Credentials;

/******************************************************************************/

struct Credentials
{
    import swarm.neo.authentication.HmacDef: Key;

    import core.stdc.ctype: isgraph;

    import ocean.transition;

    /***************************************************************************

        Limits for the length of credentials strings and files.

    ***************************************************************************/

    enum LengthLimit: size_t
    {
        /***********************************************************************

            The maximum allowed length of a client name.

        ***********************************************************************/

        Name = 100,

        /***********************************************************************

            The maximum allowed size of a file containing client credentials
            (name/key pairs) in bytes.

        ***********************************************************************/

        File = 10_000_000
    }

    /***************************************************************************

        The client name.

        Only ASCII graph characters are allowed. ASCII graph characters are
        those classified as "graph" LC_CTYPE for the POSIX locale: Letters
        digits and punctuation, i.e. all ASCII characters that are not control
        characters or white space.

        Standards:
        http://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap07.html#tag_07_03_01

    ***************************************************************************/

    public mstring name;

    /***************************************************************************

        The private client key.

    ***************************************************************************/

    public Key key;

    /***************************************************************************

        Ensures this instance complies to the limits.

    ***************************************************************************/

    invariant ( )
    {
        assert(this.name.length <= LengthLimit.Name);
    }

    /***************************************************************************

        Scans name for non-graph characters.

        Params:
            name = input client name

        Returns:
            name.length minus the index of the first non-graph character found
            or 0 if all characters in name are graph characters.

    ***************************************************************************/

    public static size_t validateNameCharacters ( cstring name )
    {
        foreach (i, c; name)
        {
            if (!isgraph(c))
                return name.length - i;
        }

        return 0;
    }
}
