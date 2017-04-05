/*******************************************************************************

    Helper class for looping requests which need to cede back to epoll.

    copyright:      Copyright (c) 2012-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.common.request.helper.LoopCeder;



/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.transition;
import ocean.io.select.client.FiberSelectEvent;



/*******************************************************************************

    Cede-able looping request class. Helper class which provides the internal
    machinery for a fiber-based async request which operates in a loop of some
    kind, and needs to be able to cede back to epoll on occasion in order to
    allow other select clients to be handled.

    The handleCeding() method should be called at the end of each loop in the
    request's handler method. After it has been called a certain number of times
    (as specified in the constructor) it will cede.

*******************************************************************************/

public class LoopCeder
{
    /***************************************************************************

        Selector event used to trigger the resumption of the request.

        Note that the event instance is not const, as it is occasionally useful
        to be able to change the event after construction. An example of this
        use case would be when a loop ceder instance is created for use with a
        request, but then, some time later, needs to be re-used for a different
        request - necessitating an event switch.

     **************************************************************************/

    public FiberSelectEvent event;


    /**************************************************************************

        The event must always be non-null.

     **************************************************************************/

    invariant ()
    {
        assert(this.event !is null, typeof(this).stringof ~ " event is null");
    }


    /***************************************************************************

        Counter, incremented each time handleCeding() is called, and reset upon
        ceding.

    ***************************************************************************/

    private uint count;


    /***************************************************************************

        The number of calls to handleCeding() after which to cede. Once this
        count is reached, the request is ceded and the counter is reset to 0.

    ***************************************************************************/

    private Const!(uint) cede_point;


    /***************************************************************************

        The default cede point.

    ***************************************************************************/

    private const uint DefaultCedePoint = 5;


    /***************************************************************************

        Constructor.

        Params:
            loop = fiber select event used to cede the request's loop
            cede_point = number of calls to handleCeding() after which to cede

    ***************************************************************************/

    public this ( FiberSelectEvent event, uint cede_point = DefaultCedePoint )
    {
        this.event = event;
        this.cede_point = cede_point;
    }


    /***************************************************************************

        Updates the counter and handles ceding once the cede point is reached.

        Returns:
            true if the request was ceded

    ***************************************************************************/

    public bool handleCeding ( )
    {
        if ( ++this.count >= this.cede_point )
        {
            this.count = 0;

            this.event.cede;

            return true;
        }

        return false;
    }
}
