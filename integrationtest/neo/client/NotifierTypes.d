/*******************************************************************************

    Types passed to client request notifier delegates.

    Extends the basic notification types in swarm.neo.client with additional
    types required by this specific client.

    Copyright: Copyright (c) 2017 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module integrationtest.neo.client.NotifierTypes;

public import swarm.neo.client.NotifierTypes;
import ocean.text.convert.Formatter;

/*******************************************************************************

    A chunk of untyped data associated with a hash key.

*******************************************************************************/

public struct RequestKeyDataInfo
{
    import ocean.transition;
    import swarm.neo.protocol.Message : RequestId;

    /// ID of the request for which the notification is occurring.
    RequestId request_id;

    /// Record key associated with notification.
    hash_t key;

    /// Data value associated with notification.
    Const!(void)[] value;

    /***************************************************************************

        Formats a description of the notification to the provided sink delegate.

        Params:
            sink = delegate to feed formatted strings to

    ***************************************************************************/

    public void toString ( scope void delegate ( cstring chunk ) sink )
    {
            sformat(sink,
            "Request #{} provided the key {} and the value {}",
            this.request_id, this.key, this.value);
    }
}
