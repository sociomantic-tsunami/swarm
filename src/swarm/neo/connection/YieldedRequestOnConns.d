/*******************************************************************************

    Utility class that keeps a queue of yielded `RequestOnConn`s and resumes
    them in the next event loop cycle. In order to work `YieldedRequestOnConns`
    needs to be registered with the `EpollSelectDispatcher` that executes the
    application event loop.

    Copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.connection.YieldedRequestOnConns;

/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.io.select.client.SelectEvent;

/******************************************************************************/

class YieldedRequestOnConns: ISelectEvent
{
    import swarm.neo.util.TreeQueue;

    /***************************************************************************

        The interface for a resumable `RequestOnConn`.

    ***************************************************************************/

    interface IYieldedRequestOnConn
    {
        /***********************************************************************

            Resumes this `RequestOnConn`.

        ***********************************************************************/

        void resume ( );
    }

    /***************************************************************************

        The queue of `RequestOnConn`s to resume.

    ***************************************************************************/

    private YieldedQueue queue;

    /***************************************************************************

        Adds `roc` to be resumed on the next event loop cycle, if it hasn't
        already been added.

        Note that this method stores `roc` in a location that is invisible to
        the GC.

        Params:
            roc = a `RequestOnConn` to be resumed on the next event loop cycle

        Returns:
            true if added or false if `roc` was already in the queue so it has
            not been added again.

    ***************************************************************************/

    public bool add ( IYieldedRequestOnConn roc )
    {
        bool first = this.queue.is_empty;

        if (this.queue.push(roc))
        {
            // Trigger the event so that it fires and is handled on the next
            // event loop cycle.
            if (first)
                this.trigger();

            return true;
        }
        else
        {
            return false;
        }
    }

    /***************************************************************************

        Removes `roc` from the queue.

        Params:
            roc = the `RequestOnConn` to be removed

        Returns:
            true if `roc` was removed or false if not found.

    ***************************************************************************/

    public bool remove ( IYieldedRequestOnConn roc )
    {
        return this.queue.remove(roc);
    }

    /***************************************************************************

        Select event handler, pops all `RequestOnConn`s from the queue and
        resumes each.

        Params:
            n = the number of times the select event was triggered since it
                fired the last time

        Returns:
            true to stay registered with epoll.

    ***************************************************************************/

    override protected bool handle_ ( ulong n )
    {
        this.queue.swapAndPop(
            (IYieldedRequestOnConn yielded) {yielded.resume();}
        );

        return true;
    }

    /***************************************************************************

        Manages the queue of `RequestOnConn`s, which are actually two queues: At
        each time only one, `queue[active]`, is active while the other queue,
        `queue[!active]`, is inactive.
        All methods except `swapAndPop()` use the active queue. `swapAndPop()`
        swaps the active and inactive queue, then pops all `RequestOnConn`s from
        the previously active and now inactive queue. This is to allow for
        pushing and removing `RequestOnConn`s while in the loop of popping.

    ***************************************************************************/

    private static struct YieldedQueue
    {
        /***********************************************************************

            The two queues of yielded `RequestOnConn`s.

        ***********************************************************************/

        private TreeQueue!(YieldedRequestOnConns.IYieldedRequestOnConn)[2] queue;

        /***********************************************************************

            Flag telling which queue `add()` and `remove()` should use.

        ***********************************************************************/

        private bool active = false;

        /***********************************************************************

            Returns:
                false if a `RequestOnConn` has been pushed and `swapAndPop()`
                was not called since then, or true otherwise.

        ***********************************************************************/

        public bool is_empty ( )
        {
            return this.queue[this.active].is_empty;
        }

        /***********************************************************************

            Pushes `roc` to the active queue if it isn't in the queue already.

            Note that this method stores `roc` in a location that is invisible
            to the GC.

            Params:
                roc = a `RequestOnConn` to be pushed to the active queue

            Returns:
                true if pushed or false if `roc` was already in the active
                queue so it has not been pushed again.

        ***********************************************************************/

        public bool push ( IYieldedRequestOnConn roc )
        {
            return this.queue[this.active].push(roc);
        }

        /***********************************************************************

            Swaps the active and inactive queues, then pops all `RequestOnConn`s
            from the now inactive queue, calling `dg` with each popped
            `RequestOnConn`.

            Params:
                dg = delegate to call with each popped `RequestOnConn`

        ***********************************************************************/

        public void swapAndPop ( void delegate ( IYieldedRequestOnConn popped_roc ) dg )
        in
        {
            assert(this.queue[!this.active].is_empty, typeof(this).stringof ~
                   ".swapAndPop: " ~
                   "Expected the inactive queue to be empty when called");
        }
        out
        {
            assert(this.queue[!this.active].is_empty, typeof(this).stringof ~
                   ".swapAndPop: " ~
                   "Expected the inactive queue to be empty when returning");
        }
        body
        {
            this.active = !this.active;

            foreach (roc; this.queue[!this.active])
                dg(roc);
        }

        /***********************************************************************

            Removes `roc` from the queue.

            Params:
                roc = the `RequestOnConn` to be removed

            Returns:
                true if `roc` was removed or false if not found.

        ***********************************************************************/

        public bool remove ( IYieldedRequestOnConn roc )
        {
            return this.queue[this.active].remove(roc);
        }
    }
}
