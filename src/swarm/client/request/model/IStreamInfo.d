/*******************************************************************************

    Interface to fetch information about the progress of a stream.

    copyright: Copyright (c) 2015-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.request.model.IStreamInfo;

import swarm.client.request.model.INodeInfo;



/*******************************************************************************

    Interface to fetch information about the progress of a stream.

*******************************************************************************/

public interface IStreamInfo : INodeInfo
{
    /***************************************************************************

        Returns:
            the number of bytes sent/received by the stream (we currently assume
            that a stream request is either sending or receiving)

    ***************************************************************************/

    public size_t bytes_handled ( );
}

