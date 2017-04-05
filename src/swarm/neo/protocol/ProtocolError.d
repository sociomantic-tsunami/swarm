/*******************************************************************************

    Protocol error exception.

    This exception is thrown if
     - data received from the remote do not comply to the protocol specification
       or
     - the behaviour of the remote does not comply to the protocol
       specification, for example, by unexpectedly shutting down a socket
       connection or assigning more requests than allowed at a time.

    Copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.protocol.ProtocolError;

/******************************************************************************/

class ProtocolError: Exception
{
    import ocean.core.Exception: ReusableExceptionImplementation;
    mixin ReusableExceptionImplementation!();

    import ocean.text.convert.Format;
    import core.stdc.stdarg;
    import ocean.transition;

    /***************************************************************************

        Sets exception information for this instance.

        Params:
            fmt   = exception message formatter (or just the message)
            items = the items to format (may be empty)

        Returns:
            this instance

    ***************************************************************************/

    public typeof(this) setFmt
        ( istring file = __FILE__, typeof(__LINE__) line = __LINE__, T ... )
        ( cstring fmt, T items )
    {
        static if (items.length)
        {
            this.setFmt_(file, line, fmt, items);
            return this;
        }
        else
        {
            return this.set(fmt, file, line);
        }
    }

   /***************************************************************************

        Throws this instance if ok is false, 0 or null.

        Params:
            ok    = condition to enforce
            fmt   = exception message formatter (or just the message)
            items = the items to format (may be empty)

        Throws:
            this instance if ok is false, 0 or null.

    ***************************************************************************/

    public void enforceFmt
        ( istring file = __FILE__, long line = __LINE__, Ok, T ... )
        ( Ok ok, cstring fmt, T params )
    {
        if (!ok)
            throw this.setFmt!(file, line, T)(fmt, params);
    }

   /***************************************************************************

        Populates the message, file & line of this instance.

        Params:
            file = input value for this.file
            line = input value for this.line
            fmt  = message formatter

    ***************************************************************************/

    private void setFmt_ ( istring file, long line, cstring fmt, ... )
    {
        this.reused_msg.length = 0;
        auto msg = this.reused_msg[];
        Format.vformat(msg, fmt, _arguments, _argptr);
        this.file = file;
        this.line = line;
    }
}

