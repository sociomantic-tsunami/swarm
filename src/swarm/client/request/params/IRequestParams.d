/*******************************************************************************

    Client request parameters base class. Contains request parameters which are
    shared between all swarm clients, as well as methods to serialize and
    deserialize the parameters to/from ubyte arrays.

    copyright:      Copyright (c) 2012-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.request.params.IRequestParams;



/*******************************************************************************

    Imports

*******************************************************************************/

import swarm.client.connection.model.INodeConnectionPoolInfo;

import swarm.client.request.context.RequestContext;

import swarm.client.request.notifier.IRequestNotification;

import swarm.Const;

import swarm.client.ClientCommandParams;

import ocean.core.Traits;

import ocean.io.select.EpollSelectDispatcher;

import ocean.io.serialize.SimpleStreamSerializer;

import ocean.io.model.IConduit: IOStream, InputStream, OutputStream;

import ocean.io.device.Array;

debug ( SwarmClient ) import ocean.io.Stdout;

import ocean.transition;

import ocean.util.log.Log;



/*******************************************************************************

    Static module logger

*******************************************************************************/

static private Logger log;
static this ( )
{
    log = Log.lookup("swarm.client.request.params.IRequestParams");
}



/*******************************************************************************

    Abstract request params class.

    Note that instances of clases derived from this base are often newed as
    scope, and should thus be allocation free. (See the resume() method in
    NodeConnectionPool for one example.)

*******************************************************************************/

public abstract class IRequestParams
{
    /***************************************************************************

        Type aliases for the convenience of derived classes.

    ***************************************************************************/

    protected alias .IRequestParams IRequestParams;
    protected alias RequestContext Context;
    protected alias .INodeConnectionPoolInfo INodeConnectionPoolInfo;
    protected alias .NodeItem NodeItem;
    protected alias .IRequestNotification IRequestNotification;
    protected alias .IOStream IOStream;
    protected alias .InputStream InputStream;
    protected alias .OutputStream OutputStream;
    protected alias .SimpleStreamSerializer SimpleStreamSerializer;
    protected alias .copyFields copyFields;
    protected alias .SizeofTuple SizeofTuple;


    /***************************************************************************

        Request command

    ***************************************************************************/

    public ICommandCodes.Value command;


    /***************************************************************************

        Request identifier

    ***************************************************************************/

    public Context context;


    /***************************************************************************

        Finished callback

    ***************************************************************************/

    public IRequestNotification.Callback notifier;


    /***************************************************************************

        Request timeout in milliseconds

    ***************************************************************************/

    public uint timeout_ms;


    /***************************************************************************

        Client-only command code. Only referred to if this.command == None.

    ***************************************************************************/

    // TODO: is this really necessary *as well as* the normal command code?
    // Couldn't they be combined?

    public ClientCommandParams.Command client_command;


    /***************************************************************************

        Node to send request to

     **************************************************************************/

    public NodeItem node;


    /***************************************************************************

        Returns:
            true if this instance describes a client-only command

    ***************************************************************************/

    public bool isClientCommand ( )
    {
        return this.client_command != ClientCommandParams.Command.None
            && this.command == ICommandCodes.E.None;
    }


    /***************************************************************************

        Calls the notifier for the current request, if the delegate is non-null.

        Params:
            address = node address
            port = node service port
            exception = exception which occurred (may be null)
            status = request status code
            notification = notification type

    ***************************************************************************/

    public void notify ( mstring address, ushort port, Exception exception,
        IStatusCodes.Value status, IRequestNotification.Type notification )
    {
        if ( this.notifier !is null )
        {
            this.notify_(( IRequestNotification info )
            {
                info.status = status;
                info.type = notification;
                info.exception = exception;
                info.nodeitem = info.NodeItem(address, port);

                try
                {
                    this.notifier(info);
                }
                catch ( Exception e )
                {
                    log.error("exception caught while calling notifier "
                              ~ "delegate: '{}' @ {}:{}",
                              getMsg(e), e.file, e.line);
                }
            });
        }
        else debug ( SwarmClient )
        {
            Stderr.formatln("No request notifier");
        }
    }


    /***************************************************************************

        Abstract method which should pass an IRequestNotification instance to
        the provided delegate.

        Params:
            info_dg = delegate to receive IRequestNotification instance

    ***************************************************************************/

    protected abstract void notify_
        ( void delegate ( IRequestNotification ) info_dg );


    /***************************************************************************

        Copies the fields of this instance from another. Copies its own fields
        then calls copy_() to allow the derived class to copy its fields.

        All fields are copied by value. (i.e. all arrays are sliced.)

        Note that the copyFields template used by this method relies on the fact
        that all the class' fields are non-private. (See template documentation
        in ocean.core.Traits for further info.)

        Params:
            params = instance to copy fields from

    ***************************************************************************/

    final public void copy ( IRequestParams params )
    {
        copyClassFields(this, params);

        this.copy_(params);
    }

    protected abstract void copy_ ( IRequestParams params );

    /***************************************************************************

        Calculates the buffer size expected by serialize() and deserialize().

        A subclass should mixin the Serialize template, which overrides this
        method and adds the size of the subclass fields.

        Returns:
            the size in bytes of all fields in this class, including padding
            bytes for alignment.

        Out:
            The returned value is an integer multiple of 8, which is the maximum
            currently supported alignment.

    ***************************************************************************/

    public abstract size_t serialized_length ( )
    out (len)
    {
        assert(!(len & 7), this.classinfo.name ~ ".serialized_length():" ~
               " The serialized length is not an integer multiple of 8 as " ~
               "required for alignment");
    }
    body
    {
        return Serial!(typeof(this.tupleof)).sizeof;
    }

    /***************************************************************************

        Serializes this instance's fields into the provided data buffer.

        All fields are serialized by value. (i.e. dynamic arrays do not include
        the length or content, just the array object itself.)

        The correct alignment of all serialised values in the data buffer must
        be maintained to avoid undefined behaviour such as accidental garbage
        collection of objects referenced from a value (which has happened with
        objects referenced in the request context). For the sake of an easier
        implementation the aligment is restricted to 8. This means:

         - The total length of the .tupleof of this class (which is the tuple of
           values to serialize) and the .tupleof of each subclass must each be
           an integer multiple of 8 bytes, including padding bytes to preserve
           the correct alignment of the individual values. This is checked at
           compile time.
         - The total alignment of the .tupleof of this class and that of each
           subclass must be at most 8 bytes. This is checked at compile time.
         - The data buffer passed to serialize() and deserialize() must be
           aligned at 8 bytes. This is checked at run time. The data buffer
           slices returned by FlexibleByteRingQueue.push()/pop() happen to
           fulfill this requirement.

        Params:
            data = slice to buffer to serialize request fields into

        In:
            - data.length must be at least serialized_length
            - (Implicit, checked by callees:) data must be aligned by 8 bytes.

    ***************************************************************************/

    final public void serialize ( void[] data )
    in
    {
        assert(data.length >= this.serialized_length,
               this.classinfo.name ~ ".serialize(): Output buffer too short");
    }
    body
    {
        auto left = this.serializeData(data).length;
        assert(left == data.length - this.serialized_length);
    }

    /***************************************************************************

        Deserializes this instance's fields from the provided data buffer.

        Params:
            data = slice to buffer to deserialize request fields from

        In:
            - data.length must be at least serialized_length
            - (Implicit, checked by callees:) data must be aligned by 8 bytes.

    ***************************************************************************/

    final public void deserialize ( void[] data )
    in
    {
        assert(data.length >= this.serialized_length,
               this.classinfo.name ~ ".serialize(): Input buffer too short");
    }
    body
    {
        auto left = this.deserializeData(data).length;
        assert(left == data.length - this.serialized_length);
    }

    /***************************************************************************

        Serializes this instance's fields into the head of the provided data
        buffer.

        In a class hierarchy each base class adds its fields to the head of data
        and returns the remaining data tail for the direct subclass to add its
        fields. Each subclass should mixin the Serialize template, which
        automatically overrides this method in that way.

        Params:
            data = slice to the buffer into whose head the request fields of
                   this class should be serialised

        Returns:
            the tail of data that was not used by this class.

    ***************************************************************************/

    protected abstract void[] serializeData ( void[] data )
    {
        return typeof(this).serializeItems(data, this.tupleof);
    }

    /***************************************************************************

        Deserializes this instance's fields from the head of the provided data
        buffer.

        In a class hierarchy each base class reads its fields from the head of
        data and returns the remaining data tail for the direct subclass to add
        its fields. Each subclass should mixin the Serialize template, which
        automatically overrides this method in that way.

        Params:
            data = slice to the buffer from whose head the request fields of
                   this class should be deserialised

        Returns:
            the tail of data that was not used by this class.

    ***************************************************************************/

    protected abstract void[] deserializeData ( void[] data )
    {
        return typeof(this).deserializeItems(data, this.tupleof);
    }

    /***************************************************************************

        Serializes items into the head of the provided data buffer.

        The following restrictions apply:
            - data must be aligned by 8 bytes.
            - The overall alignment of items must be at most 8.
            - The length of the serialized items, including padding bytes to
              maintain the aligment of each individual item, must be an integer
              multiple of 8.

        Params:
            data = slice to the buffer into whose head items should be
                   serialised

        Returns:
            the tail of data that was not used in this call.

    ***************************************************************************/

    protected static void[] serializeItems ( T ... ) ( void[] data, T items )
    {
        auto serial = Serial!(T).serialized(data);

        foreach (i, item; items)
        {
            (*serial).tupleof[i] = item;
        }

        return data[(*serial).sizeof .. $];
    }

    unittest
    {
        void instantiate ()
        {
            IRequestParams params;
            void[] dst;
            params.serializeItems(dst, 1, "aaa"[], 2.0);
        }
    }

    /***************************************************************************

        Deserializes items from the head of the provided data buffer.

        The following restrictions apply:
            - data must be aligned by 8 bytes.
            - The overall alignment of items must be at most 8.
            - The length of the serialized items, including padding bytes to
              maintain the aligment of each individual item, must be an integer
              multiple of 8.

        Params:
            data = slice to the buffer from whose head items should be
                   deserialised

        Returns:
            the tail of data that was not used in this call.

    ***************************************************************************/

    protected static void[] deserializeItems ( T ... ) ( void[] data, out T items )
    {
        auto serial = Serial!(T).serialized(data);

        foreach (i, ref item; items)
        {
            item = (*serial).tupleof[i];
        }

        return data[(*serial).sizeof .. $];
    }

    unittest
    {
        void instantiate ()
        {
            IRequestParams params;
            void[] src;
            int dst1; mstring dst2;
            params.deserializeItems(src, dst1, dst2);
        }
    }

    /***************************************************************************

        All subclasses should mixin this template. It adds the override methods
        to serialize all fields in the subclass in addition to the super class
        fields.

    ***************************************************************************/

    template Serialize ( )
    {
        public override size_t serialized_length ( )
        {
            return super.serialized_length + Serial!(typeof(this.tupleof)).sizeof;
        }

        protected override void[] serializeData ( void[] data )
        {
            return typeof(this).serializeItems(super.serializeData(data), this.tupleof);
        }

        protected override void[] deserializeData ( void[] data )
        {
            return typeof(this).deserializeItems(super.deserializeData(data), this.tupleof);
        }
    }

    /***************************************************************************

        Helper struct template to maintain the required alignment when
        serialising values.

    ***************************************************************************/

    struct Serial ( T ... )
    {
        /***********************************************************************

            The values to serialize.

        ***********************************************************************/

        T items;

        /***********************************************************************

            Sets up a pointer to this struct to serialize values into data or
            deserialise them from data.

            Params:
                data = source or destination data buffer for serialisation

            Returns:
                data.ptr cast to a pointer to this struct

            In:
                - data.length must be at least the size of this struct.
                - The alignment of data must match the alignment of this struct.

        ***********************************************************************/

        static typeof(this) serialized ( void[] data )
        in
        {
            alias typeof(*this) This;

            /*
             * The static assertions don't actually belong in the scope of this
             * function, but they have to be in a function scope or
             * This.sizeof/alignof isn't accessible. Since this is the only
             * struct method they ended up here.
             */

            static assert(This.alignof <= 8, "Sorry, but only alignment <= " ~
                          "8 is currently supported; serialising " ~ T.stringof ~
                          " requires alignment " ~ This.alignof.stringof);

            static assert(!(This.sizeof & 7), "Sorry, but integer multiples  " ~
                          "of 8 bytes are currently supported; serialised " ~
                          T.stringof ~ " data are " ~ This.sizeof.stringof ~
                          " bytes");

            assert(data.length >= This.sizeof, "input data too short, must " ~
                   "be at least " ~ This.sizeof.stringof ~ " bytes");

            assert(!(cast(size_t)data.ptr & (This.alignof - 1)),
                   "data.ptr expected to be an integer  multiple of " ~
                   This.alignof.stringof ~ " as required for the " ~
                   "alignment of serialised " ~ T.stringof);
        }
        body
        {
            return cast(typeof(this))data.ptr;
        }
    }
}

version (UnitTest)
{
    import ocean.core.Test;

    class Params : IRequestParams
    {
        long data;
        mixin Serialize!();

        protected override void notify_ ( void delegate ( IRequestNotification ) info_dg ) { }
        protected override void copy_ ( IRequestParams params ) { }
    }
}

unittest
{
    void[] data = new void[100];
    auto params = new Params;
    params.serializeItems(data, 42L);
    long after;
    params.deserializeItems(data, after);
    test!("==")(after, 42);
}
