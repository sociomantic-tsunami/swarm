/*******************************************************************************

    Test the behavior of RecordStream

    This has to be an integration test because we test the behavior of reading
    from stdin.

    Copyright:
        Copyright (c) 2018 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module integrationtest.record_stream.main;

import core.sys.posix.unistd;

import ocean.core.Test;
import ocean.io.Console;
import ocean.io.device.Device;
import ocean.transition;

import swarm.util.RecordStream;

import ocean.io.stream.Buffered;
import core.sys.posix.unistd;
import core.sys.posix.sys.wait;


version (UnitTest) {} else
public int main ()
{
    int[2] pipes;
    assert(pipe(pipes) == 0);

    if (auto pid = fork())
    {
        close(pipes[0]);
        return runSender(pid, pipes[1]);
    }
    else
    {
        close(pipes[1]);
        dup2(pipes[0], STDIN_FILENO);
        runListener();
        return 0;
    }
}

public int runSender (pid_t pid, int write_fd)
{
    mstring buffer;
    // We need the destructor to be called at the end, to close the fd
    {
        scope conduit = new FDConduit(write_fd);
        foreach (record; Input)
            record.serialize(conduit, buffer);
        foreach (str; Verbatim)
            conduit.write(str);
    }

    int status;
    auto ret = waitpid(pid, &status, 0);
    assert(ret > 0, "waitpid returned <= 0");
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

public void runListener ()
{
    size_t index;
    scope comparer = (Record r)
        {
            test!("==")(r.key, Output[index].key);
            test!("==")(r.value, Output[index].value);
            index++;
            return true;

        };
    scope stream = new StdinRecordStream(comparer);
    auto eos = stream.process();
    assert(eos, "End Of Stream not received!");
}

private const istring[] Verbatim = [
    "\n\n\n",
    "bbbbbbbbbbbbbbbb:AAAAAAAAAAAAAAAA\n",
];

private const Record[] Input = [
    // Two records without keys (values only)
    Record(null,     [ 0x52, 0x45, 0x50, 0x4F, 0x52, 0x54, 0x49, 0x4E, 0x47 ]),
    Record(null,     [ 0x20, 0x57, 0x41, 0x53 ]),
    // One records with keys (16 hex characters)
    Record([ 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42,
             0x42, 0x42, 0x42, 0x42, 0x42 ],
           [ 0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x20, 0x57, 0x6F, 0x72, 0x6C, 0x64 ]),
];

private const Record[] Output = [
    // Input
    Input[0], Input[1], Input[2],
    // Verbatim: 3 newlines = 3 empty records
    Record.init, Record.init, Record.init,
    // Ensure records after newline are processed
    Record([ 0x62, 0x62, 0x62, 0x62, 0x62, 0x62, 0x62, 0x62, 0x62, 0x62, 0x62,
             0x62, 0x62, 0x62, 0x62, 0x62 ],
           [ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 ]),

];

private final class FDConduit : Device
{
    public this (int handle)
    {
        this.handle = handle;
    }

    public ~this()
    {
        this.close();
    }
}
