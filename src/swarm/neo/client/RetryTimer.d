/*******************************************************************************

    Calls a callback repeatedly until it returns true with an increasing time
    delay between subsequent calls.

    Copyright: Copyright (c) 2016-2017 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.neo.client.RetryTimer;

import core.stdc.errno;
import stdio = core.stdc.stdio;
import core.stdc.string;
import core.sys.posix.sys.time;
import core.sys.posix.time;

import ocean.core.Verify;
import ocean.io.select.EpollSelectDispatcher;
import ocean.io.select.client.model.ISelectClient;
import ocean.meta.types.Qualifiers;
import ocean.sys.TimerFD;

import swarm.neo.util.FiberTokenHashGenerator;
import swarm.neo.util.MessageFiber;


/*******************************************************************************

    Repeatedly calls `success` until it returns true, using a timer: Whenever
    `success` returns `false` it is called again when the timer expires the next
    time.

    Initially `success` is called right away. At the same time the timer is set
    to expire after ~10 ms. When this timer expires it is set again, doubling
    the time delay up to 2.5 s, then keeping it constant.

    Throws:
        `TimerFD.TimerException` if the timer failed. This can happen only due
        to OS resource exhaustion.

*******************************************************************************/

void retry ( lazy bool success, MessageFiber fiber, EpollSelectDispatcher epoll )
{
    verify(fiber.running);

    if (success) return; // first attempt

    timespec t_start;
    clock_gettime(clockid_t.CLOCK_MONOTONIC, &t_start);

    if (success) return; // immediate first retry

    timespec t_end;
    clock_gettime(clockid_t.CLOCK_MONOTONIC, &t_end);

    scope e = new TimerFD.TimerException;
    scope timer = new TimerFD(e);
    scope event = new TimerEvent(epoll, fiber, timer, t_start, t_end);

    do
    {
        event.waiting_for_timer = true;
        fiber.suspend(event.fiber_token.create(), event);
        event.waiting_for_timer = false;
    }
    while (!success);
}

/*******************************************************************************

    Custom timer event used in `retry` functin.

    Points to external (stack allocated) `TimerFD` instance

*******************************************************************************/

private final class TimerEvent: ISelectClient
{
    /// Externally created timer reference
    TimerFD timer;
    /// Set to true while event is waiting
    bool waiting_for_timer = true;
    /// Fiber token used to suspend/resume caller context
    FiberTokenHashGenerator fiber_token;
    /// Start/end time
    timespec t_start, t_end;
    /// External poll reference
    EpollSelectDispatcher epoll;
    /// Caller fiber to suspend/resume
    MessageFiber fiber;

    /// Events handle
    override Event events ( ) {return Event.EPOLLIN;}
    /// File handle
    override Handle fileHandle ( ) {return timer.fileHandle;}

    /// Table of timer expiration delays
    static immutable delay =
    [
        timespec(0,   9_765_625),
        timespec(0,  19_531_250),
        timespec(0,  39_062_500),
        timespec(0,  78_125_000),
        timespec(0, 156_250_000),
        timespec(0, 312_500_000),
        timespec(0, 625_000_000),
        timespec(1, 250_000_000),
        timespec(2, 500_000_000)
    ];

    /// A counter for the delay to use on the next expiration.
    uint n = 0;

    /***************************************************************************

        Constructor; sets the timer to the next delay that is greater
        than the duration of the first retry, `t_end - t_start`, and
        registers this instance with epoll.

    ***************************************************************************/

    this ( EpollSelectDispatcher epoll, MessageFiber fiber, TimerFD timer,
        timespec t_start, timespec t_end )
    {
        this.timer = timer;
        this.t_start = t_start;
        this.t_end = t_end;
        this.epoll = epoll;
        this.fiber = fiber;

        auto dt = diff(t_end, t_start);

        do
        {
            this.n++;
        }
        while (greater(dt, delay[this.n]) && this.n < delay.length - 1);

        switch (this.n)
        {
            default:
                // Set the timer to expire once.
                timer.set(delay[this.n]);
                this.n++;
                break;
            case delay.length  - 2:
                // Set the timer to expire after 1.25s, then every 2.5s.
                timer.set(delay[this.n], delay[this.n + 1]);
                this.n++;
                break;
            case delay.length  - 1:
                // Set the timer to expire every 2.5s.
                timer.set(delay[this.n], delay[this.n]);
        }

        epoll.register(this);
    }

    /***************************************************************************

        Timer expiration event handler. Resumes the fiber if waiting for
        the timer, and sets the timer to the next expiration if needed.
        Returns true to stay registered in epoll; ignores event.

    ***************************************************************************/

    override bool handle ( Event event )
    {
        timer.handle();

        if (this.n <= delay.length - 2)
        {
            if (this.n < delay.length - 2)
            {
                // Set the timer to expire once.
                timer.set(delay[this.n++]);
            }
            else
            {
                // Set the timer to expire after 1.25s, then every 2.5s.
                timer.set(delay[this.n], delay[this.n + 1]);
                this.n++;
            }
        }

        if (waiting_for_timer)
            fiber.resume(fiber_token.get(), this);

        return true;
    }

    /***************************************************************************

        Unregister this instance when it goes out of scope.

    ***************************************************************************/

    ~this ( )
    {
        try
        {
            // Catch and log exceptions, so that this destructor won't
            // throw.
            if (int error_code = epoll.unregister(this))
            {
                if (error_code != ENOENT)
                {
                    stdio.fprintf(stdio.stderr, ("Error unregistering " ~
                            typeof(this).stringof ~
                            " from epoll: %s\n\0").ptr,
                            strerror(error_code));
                }
            }
        }
        catch (Exception e)
        {
            auto msg = e.message();
            stdio.fprintf(stdio.stderr, ("Error unregistering " ~
                    typeof(this).stringof ~
                    " from epoll: %.*s @%s:%u\n\0").ptr,
                    msg.length, msg.ptr, e.file.ptr, e.line);
        }
    }

}

/*******************************************************************************

    Params:
        a = a time value
        b = a time value

    Returns:
        `a > b`

*******************************************************************************/

private bool greater ( timespec a, timespec b )
{
    return (a.tv_sec == b.tv_sec)
        ? (a.tv_nsec > b.tv_nsec)
        : (a.tv_sec > b.tv_sec);
}

/*******************************************************************************

    Params:
        a = a time value
        b = a time value

    Returns:
        `a - b`

*******************************************************************************/

private timespec diff ( timespec a, timespec b )
{
    auto d = timespec(a.tv_sec - b.tv_sec, a.tv_nsec - b.tv_nsec);

    with (d) if (tv_nsec < 0)
    {
        tv_sec--;
        tv_nsec += 1_000_000_000;
    }

    return d;
}

extern (C) private
{
    enum clockid_t
    {
        CLOCK_REALTIME,
        CLOCK_MONOTONIC,
        CLOCK_PROCESS_CPUTIME_ID,
        CLOCK_THREAD_CPUTIME_ID,
        CLOCK_MONOTONIC_RAW
    }

    /***************************************************************************

        Gets the time from the clock specified with `clk_id` and stores it in
        `result`.

        Params:
            clk_id = the clock to query
            result = time value output

        Returns:
            0 on success or -1 on error; `errno` is set appropriately.

        Errors:
            EFAULT = `result` points outside the accessible address space.
            EINVAL = The `clk_id` specified is not supported on this system.

    ***************************************************************************/

    int clock_gettime(clockid_t clk_id, timespec* result);
}
