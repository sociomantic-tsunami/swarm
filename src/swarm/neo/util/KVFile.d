/*******************************************************************************

    Function to parse a file consisting of "key:value", per line.

    The file is expected to have the following format:

    ---

        key1:value1\n
        key2:value2\n
        etc...

    ---

    copyright:
        Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.neo.util.KVFile;

import ocean.transition;
import ocean.io.device.File;
import ocean.net.util.QueryParams;
import ocean.text.convert.Formatter;

/*******************************************************************************

    Parses lines from the file, passing the extracted key and value of each line
    to the provided delegate.

    Params:
        filepath = the path of the file containing content
        max_file_size_sanity = sanity check for the maximum size of the file, in
            bytes
        parse_line = delegate to which the extracted key and value of each line
            are passed. Should return null if the line is valid or a string
            containing an error message to throw

    Throws:
        - IOException on file I/O error.
        - KVFileParseException on invalid file size or content (if parse_line
          returns non-null).

*******************************************************************************/

public void parse ( cstring filepath, size_t max_file_size_sanity,
    istring delegate ( cstring, cstring ) parse_line )
{
    scope file = new File(filepath, File.ReadExisting);
    scope ( exit ) file.close;

    size_t file_length = file.length;
    if ( file_length > max_file_size_sanity )
        throw new KVFileParseException(
            format("File too large: {} bytes", file_length),
            filepath, 0);

    auto file_content = new char[file_length];
    file.read(file_content);
    parseContent(file_content, parse_line, filepath);
}

/*******************************************************************************

    Parses lines from the provided chunk of content, passing the extracted key
    and value of each line to the provided delegate.

    Note: this function is public so that it can be used in unittests, where
    reading from a real file is avoided.

    Params:
        content = content to parse
        parse_line = delegate to which the extracted key and value of each line
            are passed. Should return null if the line is valid or a string
            containing an error message to throw
        filepath = path of file that `content` was read from; used for exception
            error messages

    Throws:
        - KVFileParseException if content parse_line returns non-null

*******************************************************************************/

public void parseContent ( cstring content,
    istring delegate ( cstring, cstring ) parse_line,
    cstring filepath )
{
    int line = 1; // The current line in the input file. 1-based.
    scope parser = new QueryParams('\n', ':');

    foreach ( key, value; parser.set(content) )
    {
        if ( auto msg_base = parse_line(key, value) )
            throw new KVFileParseException(msg_base, filepath, line);
        line++;
    }
}

/***************************************************************************

    Specialised exception class containing the file and line where a parsing
    error occurred.

***************************************************************************/

public class KVFileParseException: Exception
{
    /***********************************************************************

        Constructor.

        Params:
            msg = basic error message (the parsed file and line are
                appended)
            kv_file = the name of the parsed input file
            kv_file_line = the line in the parsed input file that contains
                the error
            src_file = name of source file where exception was thrown
            src_line = line in source file where exception was thrown

    ***********************************************************************/

    public this ( cstring msg_base, cstring kv_file, uint kv_file_line,
        istring src_file = __FILE__, typeof(__LINE__) src_line = __LINE__ )
    {
        super(format("{} in registry file {} at line {}", msg_base, kv_file,
            kv_file_line));
    }
}
