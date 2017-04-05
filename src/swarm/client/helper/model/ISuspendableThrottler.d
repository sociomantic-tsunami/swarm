/*******************************************************************************

    Abstract base classes for suspendable throttlers.

    Provides a simple mechanism for throttling a set of one or more suspendable
    processes based on some condition (as defined by a derived class).

    A full usage example is given in:
        swarm.client.helper.SuspendableThrottler

    copyright:      Copyright (c) 2012-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.helper.model.ISuspendableThrottler;

/*******************************************************************************

    Imports

*******************************************************************************/

static import ocean.io.model.ISuspendableThrottler;

import swarm.client.request.context.RequestContext;
import swarm.client.request.model.ISuspendableRequest;

/*******************************************************************************

    Suspendable throttler base class for use in swarm. Extends the ocean base
    class with one addition:
        * An extra addSuspendable() method which also accepts a RequestContext.
          This method is suitable for use as a delegate to be passed directly to
          the suspendable() method of a request object. (See the Suspendable
          template in swarm.client.RequestSetup.)

*******************************************************************************/

public class ISuspendableThrottler : ocean.io.model.ISuspendableThrottler.ISuspendableThrottler
{
    /***************************************************************************

        Adds a suspendable to the list of suspendables which are to be
        throttled. If it is already in the list, nothing happens.
        Contains a context for the suspend registration.

        Params:

            c = context (unused)
            s = suspendable

    ***************************************************************************/

    public void addSuspendable ( RequestContext context, ISuspendableRequest s )
    {
        super.addSuspendable(s);
    }

    alias ocean.io.model.ISuspendableThrottler.ISuspendableThrottler.addSuspendable addSuspendable;
}

