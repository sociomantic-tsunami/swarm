/*******************************************************************************

    Mixins used to construct request setup structs. Each command method of a
    client derived from IClient should return a corresponding struct constructed
    with these mixins. The methods in the mixins allow the user to specify
    various optional parameters of the request before assigning (or scheduling)
    it to the client.

    copyright:      Copyright (c) 2012-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.RequestSetup;

import swarm.client.request.params.IChannelRequestParams;

/*******************************************************************************

    Mixin for a setup method which copies all fields from a request setup struct
    into an instance of IRequestParams.

*******************************************************************************/

public template RequestParamsSetup ( )
{
    /***************************************************************************

        Imports needed by template.

    ***************************************************************************/
    
    import ocean.transition;
    import ocean.core.Traits : FieldName;
    import swarm.client.request.params.IRequestParams;

    mixin TypeofThis;
    static assert (is(This == struct));

    /***************************************************************************

        Calls the setup_* method for all fields (data members) of the struct
        which this template is mixed into, passing them the provided request
        params class instance. The setup_* methods are expected to setup the
        corresponding fields in the request params instance.

        Params:
            params = IRequestParams instance to write into

    ***************************************************************************/

    public void setup ( IRequestParams params )
    {
        foreach ( i, f; typeof(this.tupleof) )
        {
            mixin("this.setup_" ~ FieldName!(i, This) ~ "(params);");
        }
    }
}


/*******************************************************************************

    Mixin for the fields and methods shared by all request setup structs.

*******************************************************************************/

public template RequestBase ( )
{
    import ocean.transition;
    import swarm.client.request.context.RequestContext;
    import swarm.client.request.params.IRequestParams;
    import swarm.client.request.notifier.IRequestNotification;
    import swarm.Const : ICommandCodes;

    mixin TypeofThis;
    static assert (is(This == struct));

    /***************************************************************************

        Invariant which, combined with the private opCall method, makes it
        impossible to create request instances from outside of the client.

    ***************************************************************************/

    invariant ()
    {
        assert(this.command_code, "Invalid request object -- command not set");
    }


    /***************************************************************************

        Request identifier

    ***************************************************************************/

    private RequestContext user_context;


    /***************************************************************************

        Request command

    ***************************************************************************/

    private ICommandCodes.Value command_code;


    /***************************************************************************

        Request timeout in milliseconds

    ***************************************************************************/

    private uint timeout_ms;


    /***************************************************************************

        Notification callback

    ***************************************************************************/

    private IRequestNotification.Callback notification_dg;


    /***************************************************************************

        opCall method to create an instance of a request struct from its command
        code and notifier delegate.

        Params:
            command = command code of request
            notifier = notifier callback for request

        Returns:
            request instance

    ***************************************************************************/

    static private This opCall ( ICommandCodes.Value command,
        IRequestNotification.Callback notifier )
    {
        This inst;

        inst.command_code = command;
        inst.notification_dg = notifier;
        return inst;
    }


    /***************************************************************************

        Sets the notifier delegate for a request.

        Params:
            notifier = notifier callback for request

        Returns:
            this pointer for method chaining

    ***************************************************************************/

    public This* notifier ( IRequestNotification.Callback notifier )
    {
        this.notification_dg = notifier;
        version (D_Version2)
            return &this;
        else
            return this;
    }


    /***************************************************************************

        Sets a per-I/O opertaion timeout for a request.

        Params:
            timeout_ms = millisecond timeout

        Returns:
            this pointer for method chaining

    ***************************************************************************/

    public This* timeout ( uint timeout_ms )
    {
        this.timeout_ms = timeout_ms;
        version (D_Version2)
            return &this;
        else
            return this;
    }


    /***************************************************************************

        Sets the context for a request.

        Params:
            context = request context

        Returns:
            this pointer for method chaining

    ***************************************************************************/

    public This* context ( RequestContext context )
    {
        this.user_context = context;
        version (D_Version2)
            return &this;
        else
            return this;
    }


    /***************************************************************************

        Sets the context delegate for a request to a pointer.

        Params:
            context = pointer context

        Returns:
            this pointer for method chaining

    ***************************************************************************/

    public This* context ( void* context )
    {
        this.user_context = RequestContext(context);
        version (D_Version2)
            return &this;
        else
            return this;
    }


    /***************************************************************************

        Sets the context delegate for a request to an object.

        Params:
            context = object context

        Returns:
            this pointer for method chaining

    ***************************************************************************/

    public This* context ( Object context )
    {
        this.user_context = RequestContext(context);
        version (D_Version2)
            return &this;
        else
            return this;
    }


    /***************************************************************************

        Sets the context delegate for a request to a 32/64-bit integer.

        Params:
            context = integer context

        Returns:
            this pointer for method chaining

    ***************************************************************************/

    public This* context ( hash_t context )
    {
        this.user_context = RequestContext(context);
        version (D_Version2)
            return &this;
        else
            return this;
    }


    /***************************************************************************

        Returns:
            command code of this request

    ***************************************************************************/

    public ICommandCodes.Value command ( )
    {
        return this.command_code;
    }


    /***************************************************************************

        Returns:
            user-specified context of this request

    ***************************************************************************/

    public RequestContext context ( )
    {
        return this.user_context;
    }


    /***************************************************************************

        Returns:
            notification delegate of this request

    ***************************************************************************/

    public IRequestNotification.Callback notifier ( )
    {
        return this.notification_dg;
    }


    /***************************************************************************

        Copies the value of the command member into the provided
        request params class instance.

        Params:
            params = IRequestParams instance to write into

    ***************************************************************************/

    private void setup_command_code ( IRequestParams params )
    {
        params.command = this.command_code;
    }


    /***************************************************************************

        Copies the value of the notification_dg member into the provided
        request params class instance.

        Params:
            params = IRequestParams instance to write into

    ***************************************************************************/

    private void setup_notification_dg ( IRequestParams params )
    {
        params.notifier = this.notification_dg;
    }


    /***************************************************************************

        Copies the value of the user_context member into the provided
        request params class instance.

        Params:
            params = IRequestParams instance to write into

    ***************************************************************************/

    private void setup_user_context ( IRequestParams params )
    {
        params.context = this.user_context;
    }


    /***************************************************************************

        Copies the value of the timeout_ms member into the provided
        request params class instance.

        Params:
            params = IRequestParams instance to write into

    ***************************************************************************/

    private void setup_timeout_ms ( IRequestParams params )
    {
        params.timeout_ms = this.timeout_ms;
    }
}


/*******************************************************************************

    Mixin for the methods shared by all client-commands.

*******************************************************************************/

public template ClientCommandBase ( )
{
    import ocean.transition;
    import swarm.client.ClientCommandParams;
    import swarm.client.request.notifier.IRequestNotification;
    import swarm.client.request.params.IRequestParams;

    mixin TypeofThis;
    static assert (is(This == struct));

    /***************************************************************************

        Invariant which, combined with the private opCall method, makes it
        impossible to create client-command instances from outside of the
        client.

    ***************************************************************************/

    invariant ()
    {
        assert(this.client_command, "Invalid request object -- client_command not set");
    }


    /***************************************************************************

        Client-only command code.

    ***************************************************************************/

    private ClientCommandParams.Command client_command;


    /***************************************************************************

        Notification callback

    ***************************************************************************/

    private IRequestNotification.Callback notification_dg;


    /***************************************************************************

        opCall method to create an instance of a client-command struct from its
        command code and notifier delegate.

        Params:
            command = command code of request
            notifier = notifier callback for request

        Returns:
            client-command instance

    ***************************************************************************/

    static private This opCall ( ClientCommandParams.Command command,
        IRequestNotification.Callback notifier )
    {
        This inst;

        inst.client_command = command;
        inst.notification_dg = notifier;
        return inst;
    }


    /***************************************************************************

        Copies the value of the client_command member into the provided
        request params class instance.

        Params:
            params = IRequestParams instance to write into

    ***************************************************************************/

    private void setup_client_command ( IRequestParams params )
    {
        params.client_command = this.client_command;
    }


    /***************************************************************************

        Copies the value of the notification_dg member into the provided
        request params class instance.

        Params:
            params = IRequestParams instance to write into

    ***************************************************************************/

    private void setup_notification_dg ( IRequestParams params )
    {
        params.notifier = this.notification_dg;
    }
}


/*******************************************************************************

    Mixin for the methods used by client requests which can be sent to a
    specified node.

*******************************************************************************/

public template Node ( )
{
    import ocean.transition;
    import swarm.Const;
    import swarm.client.request.params.IRequestParams;

    mixin TypeofThis;
    static assert (is(This == struct));

    /***************************************************************************

        Node to send request to

    ***************************************************************************/

    private NodeItem node_item;


    /***************************************************************************

        Sets this request to be executed on all nodes (default behavior).

    ***************************************************************************/

    public This* allNodes ( )
    {
        this.node_item = NodeItem();
        version (D_Version2)
            return &this;
        else
            return this;
    }


    /***************************************************************************

        Sets the node for a request to be sent to.

        Params:
            node = node address / port

        Returns:
            this pointer for method chaining

    ***************************************************************************/

    public This* node ( NodeItem node )
    in
    {
        assert(node.set(), "Invalid NodeItem passed to node()!");
    }
    body
    {
        this.node_item = node;
        version (D_Version2)
            return &this;
        else
            return this;
    }


    /***************************************************************************

        Sets the node for a request to be sent to.

        Params:
            address = node address (sliced)
            port = node port

        Returns:
            this pointer for method chaining

    ***************************************************************************/

    public This* node ( mstring address, ushort port )
    {
        this.node_item = NodeItem(address, port);
        version (D_Version2)
            return &this;
        else
            return this;
    }


    /***************************************************************************

        Copies the value of the node_item member into the provided
        request params class instance.

        Params:
            params = IRequestParams instance to write into

    ***************************************************************************/

    private void setup_node_item ( IRequestParams params )
    {
        params.node = this.node_item;
    }
}


/*******************************************************************************

    Mixin for the methods used by client requests which operate over a single
    channel.

*******************************************************************************/

public template Channel ( )
{
    import ocean.transition;
    import ocean.core.TypeConvert : downcast;
    import swarm.client.request.params.IRequestParams;
    import swarm.client.request.params.IChannelRequestParams;

    mixin TypeofThis;
    static assert (is(This == struct));

    /***************************************************************************

        Channel request operates on

    ***************************************************************************/

    private cstring channel_name;


    /***************************************************************************

        Sets the channel for a request.

        Params:
            channel = request channel

        Returns:
            this pointer for method chaining

    ***************************************************************************/

    public This* channel ( cstring channel )
    {
        this.channel_name = channel;
        version (D_Version2)
            return &this;
        else
            return this;
    }


    /***************************************************************************

        Copies the value of the channel_name member into the provided
        request params class instance.

        Params:
            params = IRequestParams instance to write into

    ***************************************************************************/

    private void setup_channel_name ( IRequestParams params )
    {
        auto channel_params = downcast!(IChannelRequestParams)(params);
        assert(channel_params);
        channel_params.channel = this.channel_name;
    }
}


/*******************************************************************************

    Mixin for the methods used by client requests which can be suspended
    and resumed by an ISuspendable interface.

    Assumes the existence of a type called RequestParams, which is derived from
    IRequestParams, and contains a type called RegisterSuspendableDg.

*******************************************************************************/

public template Suspendable ( )
{
    import ocean.transition;
    import ocean.core.TypeConvert : downcast;
    import swarm.client.request.params.IRequestParams;

    mixin TypeofThis;
    static assert (is(This == struct));

    /***************************************************************************

        Delegate to receive ISuspendable interface(s) from request

    ***************************************************************************/

    private RequestParams.RegisterSuspendableDg suspend_register;


    /***************************************************************************

        Sets the suspender callback for the request.

        Params:
            suspend_register = request's suspender delegate

        Returns:
            this pointer for method chaining

    ***************************************************************************/

    public This* suspendable (
        RequestParams.RegisterSuspendableDg suspend_register )
    {
        this.suspend_register = suspend_register;
        version (D_Version2)
            return &this;
        else
            return this;
    }


    /***************************************************************************

        Copies the value of the suspend register member into the provided
        request params class instance.

        Params:
            params = IRequestParams instance to write into

    ***************************************************************************/

    private void setup_suspend_register ( IRequestParams params )
    {
        auto params_ = downcast!(RequestParams)(params);
        assert(params_);

        params_.suspend_register = this.suspend_register;
    }
}


/*******************************************************************************

    Mixin for the methods used by client requests about which progress
    information can be queried via an IStreamInfo interface.

    Assumes the existence of a type called RequestParams, which is derived from
    IRequestParams, and contains a type called RegisterStreamInfoDg.

*******************************************************************************/

public template StreamInfo ( )
{
    import ocean.transition;
    import ocean.core.TypeConvert : downcast;
    import swarm.client.request.params.IRequestParams;

    mixin TypeofThis;
    static assert (is(This == struct));

    /***************************************************************************

        Delegate to receive IStreamInfo interface(s) from request

    ***************************************************************************/

    private RequestParams.RegisterStreamInfoDg stream_info_register;


    /***************************************************************************

        Sets the stream info callback for the request.

        Params:
            suspend_register = request's suspender delegate

        Returns:
            this pointer for method chaining

    ***************************************************************************/

    public This* stream_info (
        RequestParams.RegisterStreamInfoDg stream_info_register )
    {
        this.stream_info_register = stream_info_register;
        version (D_Version2)
            return &this;
        else
            return this;
    }


    /***************************************************************************

        Copies the value of the stream info register member into the provided
        request params class instance.

        Params:
            params = IRequestParams instance to write into

    ***************************************************************************/

    private void setup_stream_info_register ( IRequestParams params )
    {
        auto params_ = downcast!(RequestParams)(params);
        assert(params_);

        params_.stream_info_register = this.stream_info_register;
    }
}


version (UnitTest)
{
    import ocean.core.Tuple;
}

unittest
{
    // namespace struct to avoid providing imported symbols to
    // tested mixins
    static struct HideImport
    {
        import swarm.client.request.params.IRequestParams;
        class RequestParams : IRequestParams
        {
            alias void delegate () RegisterStreamInfoDg;
            RegisterStreamInfoDg stream_info_register;
            alias void delegate () RegisterSuspendableDg;
            RegisterSuspendableDg suspend_register;
        }
    }

    alias HideImport.RequestParams RequestParams;

    // try using each mixin separately to ensure those compile
    // and provide all necessary imports internally
        
    alias Tuple!(StreamInfo, Suspendable, Channel, RequestParamsSetup,
        ClientCommandBase, Node) Mixins;

    foreach (i, M; Mixins)
    {
        mixin ("static struct Request" ~ i.stringof ~ " { mixin M; }");
    }
}
