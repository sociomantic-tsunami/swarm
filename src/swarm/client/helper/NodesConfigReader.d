/*******************************************************************************

    Client node configuration file reader

    author:         Gavin Norman

    Reads a file with newline separated node addresses/ports. Example:

    ---

        192.168.2.128:30010
        192.168.2.128:30011

    ---

    Note: this module isn't particularly careful with memory allocations, but
    it's generally only called once in an application, so it's not a problem.

    copyright:      Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.helper.NodesConfigReader;



/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.transition;

import swarm.Const : NodeItem;

import ocean.core.Array;
import ocean.core.Enforce;

import ocean.text.util.StringSearch;

import ocean.core.TypeConvert : castFrom;

import ocean.core.array.Search : find;
import ocean.io.device.File;

import ocean.text.convert.Format;
import Integer = ocean.text.convert.Integer_tango;

version (UnitTest)
{
    import ocean.core.Test;
}


/*******************************************************************************

    Nodes config reader -- all methods are static.

*******************************************************************************/

class NodesConfigReader
{
    /***************************************************************************

        Private constructor -- prevents instantiation

    ***************************************************************************/

    private this ( ) { }


static:

    /***************************************************************************

        Array of strings used to slice lines out of the input text.

    ***************************************************************************/

    private cstring[] slices;


    /***************************************************************************

        Loads the nodes properties from the configuration file filename.

        Params:
            filename  = input file name

        Returns:
            resulting list of node properties

    ***************************************************************************/

    public NodeItem[] opCall ( cstring filename )
    {
        if ( filename is null || filename.length == 0 )
        {
            throw new Exception("Filename is null/length zero",
                                __FILE__,
                                __LINE__);
        }

        scope file = new File(filename);

        scope (exit) file.close();

        scope mstring content = new char[file.length];

        file.read(content);

        return read(content);
    }


    /***************************************************************************

        Parses text content and creates a list of node items from it.

        Text following a hash (#) is ignored, and empty lines are ignored.

        Params:
            content = text to read from

        Throws:
            Exception if the config file is malformed.

        Returns:
            resulting list of node properties

     ***************************************************************************/

    private NodeItem[] read ( cstring content )
    {
        slices.length = 0;
        enableStomping(slices);

        NodeItem[] nodeitems;

        size_t line_idx;
        foreach ( line; StringSearch!().split(slices, content, '\n') )
        {
            ++line_idx;

            auto comment_pos = line.find('#');

            // strip out any text after the hash
            line = line[0 .. comment_pos];

            // strip whitespace
            line = StringSearch!().trim(line);

            if ( !line.length )
                continue;

            // Find colon dividing ip address from port
            auto split_pos = line.find(':');

            enforce(
                split_pos < line.length,
                Format("IP address must be followed by a port name in line {}: {}",
                    line_idx, line)
            );

            // Create new node item
            auto address = line[0..split_pos];
            auto port = castFrom!(int).to!(ushort)(Integer.toInt(line[split_pos+1..$]));

            nodeitems.length = nodeitems.length + 1;
            enableStomping(nodeitems);

            nodeitems[$-1].Address = address.dup;
            nodeitems[$-1].Port = port;
        }

        slices.length = 0;
        enableStomping(slices);

        return nodeitems;
    }

    unittest
    {
        istring content = "
        127.0.0.1:4000
        127.0.0.2:5000 # comment
        # 127.0.0.3:6000";

        auto res = read(content);
        assert(res.length == 2);

        assert(res[0].Address == "127.0.0.1");
        assert(res[0].Port == 4000);

        assert(res[1].Address == "127.0.0.2");
        assert(res[1].Port == 5000);

        content = "127.0.0.1";

        testThrown!(Exception)(read(content));
    }
}
