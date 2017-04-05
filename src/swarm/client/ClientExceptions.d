/*******************************************************************************

    Custom exception types which can occur inside a swarm client. Instances of
    these exception types are passed to the user's notification delegate to
    indicate which error has occurred in the client. They are not necessarily
    actually thrown anywhere (though some are).

    copyright:      Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.ClientExceptions;


/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.transition;
import ocean.core.Exception;


/*******************************************************************************

    Base class for client exceptions. Exceptions derived from this class are

*******************************************************************************/

public class ClientException : Exception
{
    mixin DefaultExceptionCtor!();

    public typeof(this) opCall ( istring file, long line )
    {
        super.file = file;
        super.line = line;

        return this;
    }
}


/*******************************************************************************

    Exception passed to user notifier when a request is assigned and no
    responsible node can be found in the registry.

*******************************************************************************/

public class NoResponsibleNodeException : ClientException
{
    public this ( )
    {
        super("No responsible node");
    }
}


/*******************************************************************************

    Exception passed to user notifier when a request was assigned to a node
    whose connections are all busy and whose request queue (in
    NodeConnectionPool) is full.

*******************************************************************************/

public class RequestQueueFullException : ClientException
{
    public this ( )
    {
        super("Request queue full");
    }
}


/*******************************************************************************

    Exception passed to user notifier when the user-specified timeout value for
    a request is exceeded during an I/O operation.

*******************************************************************************/

public class TimedOutException : ClientException
{
    public this ( )
    {
        super("I/O operation timed out");
    }
}


/*******************************************************************************

    Exception passed to user notifier when the user-specified timeout value for
    a request is exceeded during a socket connection.

*******************************************************************************/

public class ConnectionTimedOutException : ClientException
{
    public this ( )
    {
        super("Socket connection timed out");
    }
}


/*******************************************************************************

    Exception passed to user notifier when a request receives a status code from
    the node and decides that it is a fatal error (see IRequest.statusAction()).
    In these cases, the connection to the node is immediately broken.

*******************************************************************************/

public class FatalErrorException : ClientException
{
    public this ( )
    {
        super("Status code indicates fatal error - breaking connection");
    }
}


/*******************************************************************************

    Exception passed to user notifier when an invalid channel name is passed to
    a request.

*******************************************************************************/

public class BadChannelNameException : ClientException
{
    public this ( )
    {
        super("Bad channel name");
    }
}


/*******************************************************************************

    Exception passed to user notifier when an empty value is returned from a
    user output delegate. In some cases empty values are valid, and will be sent
    to the node, in other cases they are not allowed.

*******************************************************************************/

public class EmptyValueException : ClientException
{
    public this ( )
    {
        super("Cannot put empty value");
    }
}


/*******************************************************************************

    Exception passed to user notifier when a reuqest is scheduled but the user-
    specified limit on the number of events which may be scheduled has been
    reached.

*******************************************************************************/

public class SchedulerQueueFullException : ClientException
{
    public this ( )
    {
        super("Scheduler queue full");
    }
}


/*******************************************************************************

    Exception passed to user notifier when a request with a user-specified
    timeout is assigned to a client using an epoll selector which does not
    support timeouts.

*******************************************************************************/

public class NoTimeoutsException : ClientException
{
    public this ( )
    {
        super("Epoll select dispatcher doesn't support timeouts");
    }
}
