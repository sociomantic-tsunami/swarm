/*******************************************************************************

    I/O statistics aggregated by `MessageReceiver` and `MessageSender`.
    To reset them use `IOStats.init`.

    copyright: Copyright (c) 2017 sociomantic labs GmbH. All rights reserved.

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.protocol.socket.IOStats;

/// ditto
struct IOStats
{
    import swarm.neo.util.ByteCountHistogram;

    /***************************************************************************

        Statistics of the number of messages sent/received and the message body
        sizes.

    ***************************************************************************/

    public ByteCountHistogram msg_body;

    /***************************************************************************

        Statistics of the number of `writev(2)`/`read(2)` calls and the bytes
        senta/received per call.

    ***************************************************************************/

    public ByteCountHistogram socket;

    /***************************************************************************

        A counter that is incremented when waiting for the I/O device to become
        ready after a non-blocking I/O operation failed with `EWOULDBLOCK`.

    ***************************************************************************/

    public uint num_iowait_calls;
}

