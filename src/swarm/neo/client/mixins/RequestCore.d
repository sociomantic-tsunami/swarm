/*******************************************************************************

    Definitions for core client requests.

    Copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.neo.client.mixins.RequestCore;


/*******************************************************************************

    Enum defining the different types of request that are possible.

    See swarm.neo.client.RequestHandlers for more details on the different types
    of request.

*******************************************************************************/

public enum RequestType
{
    /// A request that operates on one node at a time. The node currently being
    /// operated on may change over the request's lifetime. The nodes contacted
    /// are determined entirely by the request handler.
    SingleNode,

    /// A request that operates on one node at a time. The node currently being
    /// operated on may change over the request's lifetime. The nodes contacted
    /// are determined by a round-robin sequence.
    RoundRobin,

    /// A request that initially operates on one node but can request to operate
    /// on additional nodes. The nodes contacted are determined entirely by the
    /// request handler.
    MultiNode,

    /// A request that operates on all known nodes in parallel.
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
        NotificationUnion = type of smart union defining the different
            notification info types for the request

*******************************************************************************/

public template RequestCore ( RequestType request_type_, ubyte request_code,
    ubyte request_version, Args, SharedWorking, NotificationUnion )
{
    /***************************************************************************

        Internal imports.

    ***************************************************************************/

    import ocean.transition;
    import ocean.util.serialize.contiguous.Contiguous;

    import swarm.neo.request.Command;
    import swarm.neo.AddrPort;
    import swarm.neo.client.NotifierTypes;
    import swarm.neo.util.StructPacker;

    /***************************************************************************

        Imports needed by all requests.

    ***************************************************************************/

    import swarm.neo.client.RequestOnConn;
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

        /***********************************************************************

            Note: this struct is essentially deprecated. It is only needed in
            order to maintain the public API of UserSpecifiedParams (specifically
            the ability to call `params.notifier.set()`). In the next major
            release, the `serialized_notifier` can be moved into
            UserSpecifiedParams and this wrapper struct removed.

        ***********************************************************************/

        public struct SerializedNotifier
        {
            /// Serialized notifier delegate. (Must be serialized as the ocean
            /// contiguous serializer rejects delegates.)
            private ubyte[Notifier.sizeof] serialized_notifier;

            /*******************************************************************

                Serializes the passed notifier into this.serialized_notifier.

                Params:
                    notifier = notifier to serialize

            *******************************************************************/

            deprecated("Construct a const UserSpecifiedParams instance at once; do not set the notifier after construction.")
            public void set ( Notifier notifier )
            {
                this.serialized_notifier[] =
                    (cast(Const!(ubyte)*)&notifier)[0..notifier.sizeof];
            }
        }

        /// ditto
        public SerializedNotifier notifier;

        /***********************************************************************

            Returns:
                the previously serialized notifier, deserialized

        ***********************************************************************/

        public Notifier getNotifier ( )
        {
            return *(cast(Notifier*)(this.notifier.serialized_notifier.ptr));
        }
    }

    /***************************************************************************

        Struct that is stored as the context of the request, passed to the
        request handler.

    ***************************************************************************/

    public static struct Context
    {
        import ocean.util.serialize.contiguous.Serializer;
        import ocean.util.serialize.contiguous.Deserializer;

        /***********************************************************************

            User-specified data required by the request.

        ***********************************************************************/

        public UserSpecifiedParams user_params;

        /***********************************************************************

            Object for acquiring shared resources required by the request.

        ***********************************************************************/

        public Object shared_resources;

        /***********************************************************************

            Note: this struct is essentially deprecated. It is only needed in
            order to maintain the public API of Context. In the next major
            release, this wrapper struct can be removed.

        ***********************************************************************/

        private struct RequestResources
        {
            private Object* request_resources;

            public Object get ( )
            {
                return *this.request_resources;
            }
        }

        /***********************************************************************

            Returns:
                instance to shared resources wrapper struct

        ***********************************************************************/

        deprecated("Access `shared_resources` object directly instead.")
        public RequestResources request_resources ( )
        {
            return RequestResources(&this.shared_resources);
        }

        /***********************************************************************

            Global working data required by the request.

        ***********************************************************************/

        public SharedWorking shared_working;

        /***********************************************************************

            The ID of the request in the request set (set by RequestSet, passed
            to the notifier).

        ***********************************************************************/

        public RequestId request_id;
    }

    /***************************************************************************

        Helper function to call the user's notifier. (Public so that it can be
        called from helpers which are not declared inside the request struct.)

        Params:
            params = the parameters specified by the user (i.e. the
                request-specific arguments and the notifier delegate)
            type = type of notification

    ***************************************************************************/

    public static void notify ( ref UserSpecifiedParams params,
        NotificationUnion type )
    {
        if ( auto notifier = params.getNotifier() )
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
        Context* context, AddrPort remote_address )
    {
        switch ( status )
        {
            case SupportedStatus.RequestNotSupported:
                NotificationUnion n;
                n.unsupported = RequestNodeUnsupportedInfo();
                n.unsupported.request_id = context.request_id;
                n.unsupported.node_addr = remote_address;
                n.unsupported.type = n.unsupported.type.RequestNotSupported;

                notify(context.user_params, n);
                return true;

            case SupportedStatus.RequestVersionNotSupported:
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

        Private helper function to handle notification of the global supported
        codes, including the RequestSupported code.

        Params:
            status = code received from node
            context = deserialized request context
            remote_address = address of node which returned this status code

        Returns:
            false if `status` was a status error code and the user notified;
            true if `status` is a RequestSupported code indicating that the
            request is supported and that the request will start.

    ***************************************************************************/

    private static bool handleSupportedCodes ( SupportedStatus status,
        Context* context, AddrPort remote_address )
    {
        switch ( status )
        {
            case SupportedStatus.RequestNotSupported:
                NotificationUnion n;
                n.unsupported = RequestNodeUnsupportedInfo();
                n.unsupported.request_id = context.request_id;
                n.unsupported.node_addr = remote_address;
                n.unsupported.type = n.unsupported.type.RequestNotSupported;

                notify(context.user_params, n);
                return false;

            case SupportedStatus.RequestVersionNotSupported:
                NotificationUnion n;
                n.unsupported = RequestNodeUnsupportedInfo();
                n.unsupported.request_id = context.request_id;
                n.unsupported.node_addr = remote_address;
                n.unsupported.type = n.unsupported.type.RequestVersionNotSupported;

                notify(context.user_params, n);
                return false;

            case SupportedStatus.RequestSupported:
                return true;

            default:
                return false;
        }
        assert(false);
    }

    /***************************************************************************

        Private helper function to convert the raw, packed context into a
        Context instance.

        Params:
            context_blob = serialized context

        Returns:
            a pointer to the deserialized context struct

    ***************************************************************************/

    private static Context* getContext ( void[] context_blob )
    {
        return unpack!(Context)(context_blob);
    }
}

///
unittest
{
    // Example of using RequestCore.
    struct ExampleRequest
    {
        import ocean.core.SmartUnion;

        /***********************************************************************

            Request API. (Usually defined in a separate module and imported into
            the request internals struct.)

        ***********************************************************************/

        const ubyte RequestCode = 0;
        const ubyte RequestVersion = 0;

        struct Args
        {
            // Dummy
        }

        union NotificationUnion
        {
            import swarm.neo.client.NotifierTypes;

            RequestNodeUnsupportedInfo unsupported;
        }

        alias SmartUnion!(NotificationUnion) Notification;

        alias void delegate ( Notification, Args ) Notifier;

        /***********************************************************************

            Request internals.

        ***********************************************************************/

        private struct SharedWorking
        {
            // Dummy
        }

        /***********************************************************************

            Request core. Mixes in the types `NotificationInfo`, `Notifier`,
            `Params`, `Context` plus the static constants `request_type` and
            `request_code`.

        ***********************************************************************/

        mixin RequestCore!(RequestType.AllNodes, RequestCode, RequestVersion,
            Args, SharedWorking, Notification);
    }
}
