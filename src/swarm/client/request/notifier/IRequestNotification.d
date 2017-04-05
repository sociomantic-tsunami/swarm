/*******************************************************************************

    Client request notifier

    copyright:      Copyright (c) 2010-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.request.notifier.IRequestNotification;



/*******************************************************************************

    Imports

*******************************************************************************/

import swarm.Const;

import swarm.client.request.context.RequestContext;

import ocean.core.Array;
import ocean.core.Enum;

import ocean.transition;
import ocean.text.convert.Format;

import swarm.client.ClientExceptions : TimedOutException,
    ConnectionTimedOutException;



/*******************************************************************************

    Request notification type enum

*******************************************************************************/

class TypeEnum : IEnum
{
    mixin EnumBase!([
        "Undefined"[]:0,
        "Scheduled":1,      // request scheduled for future assignment
        "Queued":2,         // request placed in queue
        "Started":3,        // request started processing
        "Finished":4,       // request finished processing
        "GroupFinished":5   // request group finished processing
    ]);
}



/*******************************************************************************

    Request notification abstract base class

*******************************************************************************/

public scope class IRequestNotification
{
    /***************************************************************************

        Local type aliases

    ***************************************************************************/

    public alias RequestContext Context;
    public alias .NodeItem NodeItem;


    /***************************************************************************

        Error reporting callback delegate alias type definition

    ***************************************************************************/

    public alias void delegate ( typeof(this) info ) Callback;


    /***************************************************************************

        Request command

    ***************************************************************************/

    public Const!(ICommandCodes.Value) command;


    /***************************************************************************

        Request context

    ***************************************************************************/

    protected Context context_;


    /***************************************************************************

        Notification type

        Note that a request overflow notification is not necessary, as the user
        is already notified of this event, either by an error notification (in
        the case where no overflow handler exists), or by the overflow handler's
        push delegate being called.

    ***************************************************************************/

    public alias TypeEnum.E Type;

    public Type type = Type.Undefined;


    /***************************************************************************

        Exception caught while handling a request (just client side exceptions,
        obviously).

    ***************************************************************************/

    public Exception exception;


    /***************************************************************************

        Properties of node which reported an error status.

    ***************************************************************************/

    public NodeItem nodeitem;


    /***************************************************************************

        Status code (either set by client or received from node).

    ***************************************************************************/

    public IStatusCodes.Value status = IStatusCodes.E.Undefined;


    /***************************************************************************

        Maps from command / status codes to description strings

    ***************************************************************************/

    private ICommandCodes command_codes;

    private IStatusCodes status_codes;


    /***************************************************************************

        Description string used when map lookup for a code fails.

    ***************************************************************************/

    private const istring invalid_code = "INVALID";


    /***************************************************************************

        Constructor.

        Params:
            command_descriptions = map from codes to command description strings
            status_descriptions = map from codes to status description strings
            command = command of request to notify about
            context = context of request to notify about

    ***************************************************************************/

    public this ( ICommandCodes command_codes, IStatusCodes status_codes,
        ICommandCodes.Value command, Context context )
    {
        this.command_codes = command_codes;
        this.status_codes = status_codes;
        this.command = command;
        this.context_ = context;
    }


    /***************************************************************************

        Tells whether the notification indicates that the request succeeded,
        based on the following criteria:
            1. This is a finished notification.
            2. The status is Ok.
            3. An exception was not thrown while handling the request.

        Returns:
            true if this notification indicates a request has succeeded

    ***************************************************************************/

    public bool succeeded ( )
    {
        return this.type == Type.Finished && this.exception is null
            && this.status == this.status_codes.E.Ok;
    }


    /***************************************************************************

        Tells whether the notification indicates that the request timed out.

        Returns:
            true if this notification indicates a request has timed out

    ***************************************************************************/

    public bool timed_out ( )
    {
        return this.io_timed_out || this.connection_timed_out;
    }


    /***************************************************************************

        Tells whether the notification indicates that the request timed out
        during an I/O operation.

        Returns:
            true if this notification indicates a request has timed out during
            an I/O operation

    ***************************************************************************/

    public bool io_timed_out ( )
    {
        return (cast(TimedOutException)this.exception) !is null;
    }


    /***************************************************************************

        Tells whether the notification indicates that the request timed out
        during a socket connection.

        Returns:
            true if this notification indicates a request has timed out during
            a socket connection

    ***************************************************************************/

    public bool connection_timed_out ( )
    {
        return (cast(ConnectionTimedOutException)this.exception) !is null;
    }


    /***************************************************************************

        Sets error message string based on the status code and exception.

        Params:
            message_ = buffer to receive formatted message

        Returns:
            formatted message string

    ***************************************************************************/

    public mstring message ( ref mstring message_ )
    {
        message_.length = 0;
        enableStomping(message_);

        if ( this.exception is null )
        {
            Format.format(message_, "{}: {}:{}, {} request, status {}",
                this.notification_description,
                this.nodeitem.Address, this.nodeitem.Port,
                this.command_description, this.status_description);
        }
        else
        {
            if ( this.exception.file.length )
            {
                Format.format(message_, "{}: {}:{}, {} request, status {}, exception '{}' @{}:{}",
                    this.notification_description,
                    this.nodeitem.Address, this.nodeitem.Port,
                    this.command_description, this.status_description,
                    getMsg(this.exception), this.exception.file, this.exception.line);
            }
            else
            {
                Format.format(message_, "{}: {}:{}, {} request, status {}, exception '{}'",
                    this.notification_description,
                    this.nodeitem.Address, this.nodeitem.Port,
                    this.command_description, this.status_description,
                    getMsg(this.exception));
            }
        }

        return message_;
    }


    /***************************************************************************

        Returns:
            Request context

    ***************************************************************************/

    public Context context ()
    {
        return this.context_;
    }


    /***************************************************************************

        Returns:
            the notification type description string

    ***************************************************************************/

    public cstring notification_description ( )
    {
        auto desc = this.type in TypeEnum();
        return desc ? *desc : this.invalid_code;
    }


    /***************************************************************************

        Returns:
            the command code description string

    ***************************************************************************/

    public cstring command_description ( )
    {
        auto desc = this.command in this.command_codes;
        return desc ? *desc : this.invalid_code;
    }


    /***************************************************************************

        Returns:
            the status code description string

    ***************************************************************************/

    public cstring status_description ( )
    {
        auto desc = this.status in this.status_codes;
        return desc ? *desc : this.invalid_code;
    }
}
