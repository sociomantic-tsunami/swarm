/*******************************************************************************

    Interfaces to the request set and individual requests.

    IRequestSet, IRequest, and IRequestOnConn exist solely to break the circular
    import between `swarm.neo.client.RequestSet` and
    `swarm.neo.client.Connection`. This circular import sometimes causes
    the compilation to fail with random unrelated errors.

    Copyright: Copyright (c) 2016-2017 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.neo.client.IRequestSet;

import ocean.transition;

/*******************************************************************************

    Interface to the request set, as used by `Connection`.

*******************************************************************************/

interface IRequestSet
{
    /// The global limit of active requests at a time.
    public static immutable max_requests = 5_000;

    import swarm.neo.protocol.Message: RequestId;
    IRequest getRequest ( RequestId id );
}

/*******************************************************************************

    Interface to a request, as used by `Connection`.

*******************************************************************************/

interface IRequest
{
    /// Request implementation function to be called when the last handler of
    /// the request has finished.
    public alias void function ( void[] context_blob ) FinishedNotifier;

    import swarm.neo.AddrPort;
    import swarm.neo.protocol.ProtocolError;
    IRequestOnConn getRequestOnConnForNode ( AddrPort node_address, ProtocolError e );
}

/*******************************************************************************

    Interface to a request-on-conn, as used by `Connection`.

*******************************************************************************/

interface IRequestOnConn
{
    void getPayloadForSending ( scope void delegate ( in void[][] payload ) send );
    void setReceivedPayload ( Const!(void)[] payload );
    void error ( Exception e );
    void reconnected ( );
}

/*******************************************************************************

    Interface to a request which provides functionality required to influence
    it from the user level. This functionality is used in the creation of
    request "controllers".

*******************************************************************************/

interface IRequestController
{
    void[] context_blob ( );

    void resumeSuspendedHandlers ( int resume_code );
}
