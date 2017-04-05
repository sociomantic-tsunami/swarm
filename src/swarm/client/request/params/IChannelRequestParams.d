/*******************************************************************************

    Channel-based client request parameters base class. Extends the
    IRequestParams base class, adding a channel field.

    copyright:      Copyright (c) 2012-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.request.params.IChannelRequestParams;



/*******************************************************************************

    Imports

*******************************************************************************/

import swarm.client.request.params.IRequestParams;

import ocean.transition;
import ocean.core.Traits;

public abstract class IChannelRequestParams : IRequestParams
{
    /***************************************************************************

        Channel (slice)

     **************************************************************************/

    public cstring channel;


    /***************************************************************************

        Copies the fields of this instance from another. Copies its own fields
        then calls copy__() to allow the derived class to copy its fields.

        All fields are copied by value. (i.e. all arrays are sliced.)

        Note that the copyFields template used by this method relies on the fact
        that all the class' fields are non-private. (See template documentation
        in ocean.core.Traits for further info.)

        Params:
            params = instance to copy fields from

    ***************************************************************************/

    override final protected void copy_ ( IRequestParams params )
    {
        auto channel_params = cast(IChannelRequestParams)params;
        copyClassFields(this, channel_params);

        this.copy__(params);
    }

    protected abstract void copy__ ( IRequestParams params );

    /***************************************************************************

        Add the serialisation override methods, declaring them abstract

    ***************************************************************************/

    abstract: mixin Serialize!();
}
