/*******************************************************************************

    Reads the credentials, a mapping from auth names to their keys, from a
    file.

    The file is expected to have the following format:

    ---

        name1:key1\n
        name2:key2\n
        etc...

    ---

    The file size may be at most Credentials.LengthLimit.File bytes.

    Each name must consist of ASCII graph characters (LC_CTYPE class in the
    POSIX locale, i.e. alphanumeric or punctuation, not white space or control
    characters), not be empty and have a length of at most
    Credentials.LengthLimit.Name.

    Each key must encoded as a hexadecimal string (case insensitive).
    The length of each key must be Credentials.LengthLimit.Key bytes. This
    refers to the actual key, not its hexadecimal encoding, so the length of the
    hexadecimal string in the file representing the key must be
    Credentials.LengthLimit.Key * 2.

    copyright:
        Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.neo.authentication.CredentialsFile;

import NodeCred = swarm.neo.authentication.NodeCredentials;
import CredDef = swarm.neo.authentication.Credentials;
import HmacDef = swarm.neo.authentication.HmacDef;
import KVFile = swarm.neo.util.KVFile;

import swarm.util.Hash : isHex;
import ocean.text.convert.Hex : hexToBin;
import ocean.text.convert.Formatter;

import ocean.transition;

debug ( SwarmConn )
    import ocean.io.Stdout;

deprecated("Replace imports of CredentialsFile with Credentials in "
    "swarm.neo.authentication.NodeCredentials")
public alias NodeCred.Credentials CredentialsFile;

/***************************************************************************

    Updates the credentials from the file, and changes this instance to
    refer to the updated credentials on success. On error this instance will
    keep referring to the same credentials.

    Params:
        filepath = the path of the file containing content

    Returns:
        the authorisation keys by name

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

public HmacDef.Key[istring] parse ( cstring filepath )
{
    Credentials credentials;

    KVFile.parse(filepath, CredDef.LengthLimit.File,
        &credentials.parseLine);

    return credentials.reg.rehash;
}

/// Type of exception thrown on parse error.
deprecated("Replace usages of CredentialsParseException with KVFileParseException")
public alias KVFile.KVFileParseException CredentialsParseException;

/// Struct wrapping a credentials map and a method to parse them from the file.
private struct Credentials
{
    /// Registry of parsed auth name -> keys.
    public HmacDef.Key[istring] reg;

    /***************************************************************************

        Parses the auth name and key read from a single line of the file.

        Params:
            auth_name = auth name read from file
            auth_key = auth key read from file

        Returns:
            null if parsing succeeded, otherwise an error message

    ***************************************************************************/

    public istring parseLine ( cstring auth_name, cstring auth_key )
    {
        if ( auth_name.length == 0 )
            return "Empty name";

        if ( auth_name.length > CredDef.LengthLimit.Name )
            return "Name too long";

        if ( auto x = CredDef.validateNameCharacters(auth_name) )
        {
            return format("Invalid name letter at position {}",
                auth_name.length - x);
        }

        if ( auth_key.length != HmacDef.Key.length * 2 )
            return format("Invalid key length {} (should be {})",
                auth_key.length, HmacDef.Key.length * 2);

        foreach ( i, c; auth_key )
            if ( !isHex(c) )
                return format("Invalid key character at position {}", i);

        // Convert key string to binary
        HmacDef.Key hmac_key;
        ubyte[] binary_key;
        hexToBin(auth_key, binary_key);
        assert(binary_key.length == HmacDef.Key.length);
        hmac_key.content[] = binary_key[];

        // Add parsed credentials to map
        this.reg[auth_name] = hmac_key;

        return null;
    }
}

/******************************************************************************/

version ( UnitTest )
{
    import ocean.core.Test;
    import ocean.core.ByteSwap;

    /***************************************************************************

        Tests the functioning of parseContent().
        Params:
            name = name of test
            file_content = content of authorisation registration file
            expected = name->key map of expected results after extracting file
                content
        Throws:
            TestException on failure

    ***************************************************************************/

    void registryTest ( istring name, istring file_content,
        HmacDef.Key[istring] expected )
    {
        Credentials credentials;
        auto t = new NamedTest(name);
        KVFile.parseContent(file_content, &credentials.parseLine, name);

        t.test!("==")(credentials.reg.keys.length, expected.length);

        foreach ( client, key; expected )
        {
            t.test!("in")(client, credentials.reg);
            t.test!("==")((client in credentials.reg).content, key.content);
        }
    }

    /***************************************************************************

        Creates a key from words.

        Params:
            words = the 16 data words the key consists of, each in reverse byte
                    order

        In:
            The total byte length of words must be Credentials.Length.key.

    ***************************************************************************/

    HmacDef.Key makeKey ( ulong[] words ... )
    in
    {
        assert(words.length == HmacDef.Key.length / words[0].sizeof);
    }
    body
    {
        HmacDef.Key key;
        (cast(ulong[])key.content)[] = words;
        ByteSwap.swap64(key.content);
        return key;
    }
}


/*******************************************************************************

    Tests for HmacKeyRegistryFile.extractKeys() with different endings
    (\n / eof).

*******************************************************************************/

unittest
{
    // Empty
    registryTest("Empty", [], (HmacDef.Key[istring]).init);

    // One entry then EOF
    registryTest(
        "EOF",
        "client1:7DB4B1840EFB9CCC1E954305F7C9C76852541CC34257AD9A6C0FF2C5822A191436B2701F95798067B90D6E46EC8E315AE8D736F8B54ADFF08D760C1091C76070E83476B8CF3F97DBDAA254A13F1EE985952D17D5103E007B2CD51AE260CF4CF67607E6B768B2FE361E706E545E7197EED7C6E71A90E1A84A0FA0900242EECBE5",
        ["client1": makeKey(0x7DB4B1840EFB9CCC, 0x1E954305F7C9C768, 0x52541CC34257AD9A, 0x6C0FF2C5822A1914, 0x36B2701F95798067, 0xB90D6E46EC8E315A, 0xE8D736F8B54ADFF0, 0x8D760C1091C76070, 0xE83476B8CF3F97DB, 0xDAA254A13F1EE985, 0x952D17D5103E007B, 0x2CD51AE260CF4CF6, 0x7607E6B768B2FE36, 0x1E706E545E7197EE, 0xD7C6E71A90E1A84A, 0x0FA0900242EECBE5)]
    );

    // One entry then \n
    registryTest(
        "One line",
        "client1:172D054EA0B0793D4810F65CD9F625118C7CE06BF493CE1336D3B8858403DAF910E45CFF678FD3F4230401520EB6DF66620DDE64A7AB9486972978FED3FE4E70020861E3E17D3443843CA4D9A14794184FD87D31420B92BF761FA298E2ECDDE2D0630AC2BAE06A6208D5B3D200A585FED14E0FFB026320669929D743047A9E87\n",
        ["client1": makeKey(0x172D054EA0B0793D, 0x4810F65CD9F62511, 0x8C7CE06BF493CE13, 0x36D3B8858403DAF9, 0x10E45CFF678FD3F4, 0x230401520EB6DF66, 0x620DDE64A7AB9486, 0x972978FED3FE4E70, 0x020861E3E17D3443, 0x843CA4D9A1479418, 0x4FD87D31420B92BF, 0x761FA298E2ECDDE2, 0xD0630AC2BAE06A62, 0x08D5B3D200A585FE, 0xD14E0FFB02632066, 0x9929D743047A9E87)]
    );

    // Two entries then EOF
    registryTest(
        "Two lines, EOF",
        "client1:D6153B8CF3639D5B9FFCC98FE4C1EB6D3BD2A7587749FDBAFDCD739A3F94398CAF8579C41A3ACD7B5A84AFB079B71163F1C912CC8A6E45AF3E1617A4EECB8BB9819E6E31F4AB47939BECB7206CEB5E53BEF71152852735EFFD593D945D22FF802FAB9EE32D9E4014FFD0EEF22BD7B62F204DB8A9A5A4638B008EB66ADFC3E4A9\n" ~
        "client2:F530D4EC26CABFED56524521CFAA25E54A2037A6DAFFF6782468E7D4DA40E539AE45897CAD131522F1394518C4B22958E02A32664D6E0C1E452E5F7AE95048F460BF90D4E704EC61121EA07E17E560B78DE7DC20A83CE5E3E4CB77CCB82B2B47EE68AA5E8002CE92561AC953363BC098CFC7BD96281B463EC7B560E69A7D886E",
        [
            "client1": makeKey(0xD6153B8CF3639D5B, 0x9FFCC98FE4C1EB6D, 0x3BD2A7587749FDBA, 0xFDCD739A3F94398C, 0xAF8579C41A3ACD7B, 0x5A84AFB079B71163, 0xF1C912CC8A6E45AF, 0x3E1617A4EECB8BB9, 0x819E6E31F4AB4793, 0x9BECB7206CEB5E53, 0xBEF71152852735EF, 0xFD593D945D22FF80, 0x2FAB9EE32D9E4014, 0xFFD0EEF22BD7B62F, 0x204DB8A9A5A4638B, 0x008EB66ADFC3E4A9),
            "client2": makeKey(0xF530D4EC26CABFED, 0x56524521CFAA25E5, 0x4A2037A6DAFFF678, 0x2468E7D4DA40E539, 0xAE45897CAD131522, 0xF1394518C4B22958, 0xE02A32664D6E0C1E, 0x452E5F7AE95048F4, 0x60BF90D4E704EC61, 0x121EA07E17E560B7, 0x8DE7DC20A83CE5E3, 0xE4CB77CCB82B2B47, 0xEE68AA5E8002CE92, 0x561AC953363BC098, 0xCFC7BD96281B463E, 0xC7B560E69A7D886E)
        ]
    );

    // Two entries then \n
    registryTest(
        "Two lines, EOF",
        "client1:0D0EAD455E7DD93A2EF1DAD3C75CB01AE2B6C92E92AECDF67C1CE9EB521AC61EC6AD477EE5F5CCB7C9DB6E28BCAB6B2478FC9738053CD5359D15523961E1AD1278123B441FF6385EEA22BBFB0F055C0925542230600925B03C462F5F305355B00607B377B8E2A2872EE27E172E62D2C9672F1BC7E0C63D111F23BC1B121CD367\n" ~
        "client2:4A5B6813572E3A3533019261E8ACA204EF7A5FFB1BD6B1A2D107DF5783AB45B0A3853665FE6C2B476E07B48BFD7E31E025558B05AE6B99E0923678AFB207627AF52808D758D7FB422F3E9A87709F76037235950329257667D1B0FA36A1920FCB23902BA81152E10213412A7DAF87271C540DFAC5C93201EE546BB036A37891E1\n",
        [
            "client1": makeKey(0x0D0EAD455E7DD93A, 0x2EF1DAD3C75CB01A, 0xE2B6C92E92AECDF6, 0x7C1CE9EB521AC61E, 0xC6AD477EE5F5CCB7, 0xC9DB6E28BCAB6B24, 0x78FC9738053CD535, 0x9D15523961E1AD12, 0x78123B441FF6385E, 0xEA22BBFB0F055C09, 0x25542230600925B0, 0x3C462F5F305355B0, 0x0607B377B8E2A287, 0x2EE27E172E62D2C9, 0x672F1BC7E0C63D11, 0x1F23BC1B121CD367),
            "client2": makeKey(0x4A5B6813572E3A35, 0x33019261E8ACA204, 0xEF7A5FFB1BD6B1A2, 0xD107DF5783AB45B0, 0xA3853665FE6C2B47, 0x6E07B48BFD7E31E0, 0x25558B05AE6B99E0, 0x923678AFB207627A, 0xF52808D758D7FB42, 0x2F3E9A87709F7603, 0x7235950329257667, 0xD1B0FA36A1920FCB, 0x23902BA81152E102, 0x13412A7DAF87271C, 0x540DFAC5C93201EE, 0x546BB036A37891E1)
        ]);
}
