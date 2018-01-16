/*******************************************************************************

    Node credentials

    copyright: Copyright (c) 2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.neo.authentication.NodeCredentials;

/// ditto
public class Credentials
{
    import swarm.neo.authentication.Credentials;
    import CredFile = swarm.neo.authentication.CredentialsFile;
    import HmacDef = swarm.neo.authentication.HmacDef;

    import ocean.transition;
    import ocean.io.device.File;
    import ocean.net.util.QueryParams;

    /***************************************************************************

        The credentials registry. A pointer to it can be obtained by
        `credentials()`, it changes when `update()` is called.

    ***************************************************************************/

    private HmacDef.Key[istring] credentials_;

    /***************************************************************************

        The credentials file path.

    ***************************************************************************/

    private istring filepath;

    /***************************************************************************

        Constructor, reads the credentials from the file (by calling
        `update()`).

        Params:
            filepath = the credentials file path

        Throws:
            See `update()`.

    ***************************************************************************/

    public this ( istring filepath )
    {
        this.filepath = filepath;
        this.update();
    }

    /***************************************************************************

        Obtains a pointer to the credentials, which change if `update` is
        called.

        Returns:
            a pointer to the credentials.

    ***************************************************************************/

    public Const!(HmacDef.Key[istring])* credentials ( )
    {
        return &this.credentials_;
    }

    /***************************************************************************

        Updates the credentials from the file, and changes this instance to
        refer to the updated credentials on success. On error this instance will
        keep referring to the same credentials.

        Throws:
            - IOException on file I/O error.
            - ParseException on invalid file size or content; that is, if
              - the file size is greater than Credentials.LengthLimit.File,
              - a name
                - is empty (zero length),
                - is longer than Credentials.LengthLimit.File,
                - contains non-graph characters,
              - a key
                - is empty (zero length),
                - is longer than Credentials.LengthLimit.File * 2,
                - has an odd (not even) length,
                - contains non-hexadecimal digits.

    ***************************************************************************/

    public void update ( )
    {
        this.credentials_ = CredFile.parse(this.filepath);
    }
}
