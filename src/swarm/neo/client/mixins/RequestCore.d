/*******************************************************************************

    Definitions for core client requests.

    Copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.client.mixins.RequestCore;


/*******************************************************************************

    Enum defining the different types of request that are possible.

*******************************************************************************/

public enum RequestType
{
    SingleNode,
    RoundRobin,
    AllNodes
}

/*******************************************************************************

    Template mixin containing the core required by request controller structs.
    (Just an instance of IRequestController.)

*******************************************************************************/

public template ControllerBase ( )
{
    import swarm.neo.client.IRequestSet : IRequestController;

    private IRequestController request_controller;

    public this ( IRequestController request_controller )
    {
        this.request_controller = request_controller;
    }
}

/*******************************************************************************

    Helper struct allowing a reference type to be serialized by the contiguous
    serializer (it normally refuses to serialize reference types).

*******************************************************************************/

public static struct SerializableReferenceType ( Type )
{
    ubyte[Type.sizeof] serialized;

    void set ( Type val )
    {
        this.serialized[] = (cast(ubyte*)&val)[0..val.sizeof];
    }

    Type get ( )
    {
        return *(cast(Type*)this.serialized.ptr);
    }
}

/*******************************************************************************

    Template mixin containing the core required by request structs.

    Request structs act simply as namespaces for the collection of symbols
    required to implement a request. They are never instantiated and have no
    fields or non-static functions.

    The client expects several things to be present in a request struct:
        1. The static constants request_type and request_code
        2. The UserSpecifiedParams struct, containing all user-specified request
            setup (including a notifier)
        3. The Notifier delegate type
        4. Optionally, the Controller type (if the request can be controlled,
           after it has begun)
        5. The handler() function
        6. The all_finished_notifier() function

    This mixin provides items 1 and 2. 3, (4), 5, and 6 must be added manually
    in each request struct.

    Params:
        request_type = type of request (all-nodes, round-robin, single-node)
        request_code = ubyte code which identifies this request
        request_version = ubyte version number of this request
        Args = type containing user-specified request-specific arguments (i.e.
            excluding the request notifier, which is required by all requests)
        SharedWorking = type containing data which the request needs while it is
            in progress. A single instance of this struct is stored for the
            whole request (as part of the request context, see below) and is
            shared by each connection which is active
        RoCWorking = type containing data which a RequestOnConn needs while it
            is in progress. An instance of this struct is stored per connection
            on which the request runs and is passed to the request handler
        NotificationUnion = type of smart union defining the different
            notification info types for the request

*******************************************************************************/

public template RequestCore ( RequestType request_type_, ubyte request_code,
    ubyte request_version, Args, SharedWorking, RoCWorking,
    NotificationUnion )
{
    /***************************************************************************

        Internal imports.

    ***************************************************************************/

    import ocean.transition;
    import ocean.util.serialize.contiguous.Contiguous;

    import swarm.neo.request.Command;
    import swarm.neo.IPAddress;
    import swarm.neo.client.NotifierTypes;

    /***************************************************************************

        Imports needed by all requests.

    ***************************************************************************/

    import swarm.neo.client.RequestOnConn;
    import swarm.neo.client.IRequestSet : IRequestWorkingData;
    import swarm.neo.protocol.Message : RequestId;

    /***************************************************************************

        Mixin `This`.

    ***************************************************************************/

    private mixin TypeofThis!();

    /***************************************************************************

        Static check that the request struct has no members. (Request structs
        just act as namespaces; they should never be instantiated.)

    ***************************************************************************/

    static assert(This.tupleof.length == 0,
        "Request structs should have no fields");

    /***************************************************************************

        The type of the request (round-robin, all nodes, or single node).

    ***************************************************************************/

    const RequestType request_type = request_type_;

    /***************************************************************************

        The `Command` struct storing the request code and version.

    ***************************************************************************/

    static Const!(Command) cmd = Command(request_code, request_version);

    /***************************************************************************

        Struct containing all user-specified parameters of the request: a Args
        instance plus the notifier delegate. This is stored in the context of
        the request (see below). The Args element is passed to the notifier.

    ***************************************************************************/

    public static struct UserSpecifiedParams
    {
        public Args args;

        public SerializableReferenceType!(Notifier) notifier;
    }

    /***************************************************************************

        Struct that is stored as the context of the request, passed to the
        request handler.

    ***************************************************************************/

    public static struct Context
    {
        /***********************************************************************

            User-specified data required by the request.

        ***********************************************************************/

        public UserSpecifiedParams user_params;

        /***********************************************************************

            Global working data required by the request.

        ***********************************************************************/

        public SharedWorking shared_working;

        /***********************************************************************

            Object for acquiring resources required by the request.

        ***********************************************************************/

        public SerializableReferenceType!(Object) request_resources;

        /***********************************************************************

            The ID of the request in the request set (set by RequestSet, passed
            to the notifier).

        ***********************************************************************/

        public RequestId request_id;
    }

    /***************************************************************************

        Private helper function to call the user's notifier.

        Params:
            params = the parameters specified by the user (i.e. the
                request-specific arguments and the notifier delegate)
            type = type of notification

    ***************************************************************************/

    private static void notify ( ref UserSpecifiedParams params,
        NotificationUnion type )
    {
        if ( auto notifier = params.notifier.get() )
        {
            notifier(type, params.args);
        }
    }

    /***************************************************************************

        Private helper function to handle notification of the global status
        codes.

        Params:
            status = code received from node
            context = deserialized request context
            remote_address = address of node which returned this status code

        Returns:
            true if `status` was a global code and the user notified; false if
            `status` is a request-specific code which the caller should
            interpret and handle

    ***************************************************************************/

    private static bool handleGlobalStatusCodes ( StatusCode status,
        Context* context, IPAddress remote_address )
    {
        switch ( status )
        {
            case GlobalStatusCode.RequestNotSupported:
                NotificationUnion n;
                n.unsupported = RequestNodeUnsupportedInfo();
                n.unsupported.request_id = context.request_id;
                n.unsupported.node_addr = remote_address;
                n.unsupported.type = n.unsupported.type.RequestNotSupported;

                notify(context.user_params, n);
                return true;

            case GlobalStatusCode.RequestVersionNotSupported:
                NotificationUnion n;
                n.unsupported = RequestNodeUnsupportedInfo();
                n.unsupported.request_id = context.request_id;
                n.unsupported.node_addr = remote_address;
                n.unsupported.type = n.unsupported.type.RequestVersionNotSupported;

                notify(context.user_params, n);
                return true;

            default:
                return false;
        }
        assert(false);
    }

    /***************************************************************************

        Private helper function to convert the raw, serialized context into a
        Context instance.

        Params:
            context_blob = serialized context

        Returns:
            a pointer to the deserialized context struct

    ***************************************************************************/

    private static Context* getContext ( void[] context_blob )
    {
        return Contiguous!(Context)(context_blob).ptr;
    }

    /***************************************************************************

        Private helper function to convert the raw, serialized working data into
        an RoCWorking instance.

        Params:
            working_blob = serialized working data

        Returns:
            a pointer to the deserialized working data struct

    ***************************************************************************/

    private static RoCWorking* getWorkingData ( void[] working_blob )
    {
        return Contiguous!(RoCWorking)(working_blob).ptr;
    }
}

