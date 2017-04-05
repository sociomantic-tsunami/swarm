/*******************************************************************************

    Base class for asynchronously/selector managed fiber-based client requests

    Base class for client requests with the following proceudre:
        1. Send the server the data required for the request.
        2. Receive the status code from the server.
        3. If the status code is valid, then handle the request, calling the
           abstract handle__() method.
        4. If the status code is not valid, the derived class must decide
           whether it represents a fatal error, or a recoverable error. The
           statusActionSkip() method is called in the latter case, allowing
           the connection to be reused for the next command. The
           statusActionFatal() method is called for the former case, and
           an exception is thrown, causing the connection to be broken.

    copyright:      Copyright (c) 2010-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.client.request.model.IRequest;



/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.core.Array;
import ocean.core.SmartEnum;

import swarm.client.ClientExceptions : FatalErrorException;

import swarm.common.request.model.IFiberRequest;

import swarm.client.request.params.IRequestParams;

import swarm.client.request.context.RequestContext;



/*******************************************************************************

    Abstract request base class.

*******************************************************************************/

public abstract scope class IRequest: IFiberRequest
{
    /**************************************************************************

        Actions to take after receiving a status code from the server.

     **************************************************************************/

    protected enum StatusAction
    {
        Handle,     // Status ok, continue handling this request as normal.
        Skip,       // Status non-ok, do not handle this request, leave the
                    // connection to the server open.
        Fatal       // Error status, do not handle this request, and break the
                    // connection to the server.
    }


    /***************************************************************************

        Parameters for this request.

    ***************************************************************************/

    protected IRequestParams params_;


    /***************************************************************************

        Re-useable exception thrown in case of receiving an error status code
        from the server. Passed into the constructor.

    ***************************************************************************/

    private FatalErrorException fatal_error_exception;


    /***************************************************************************

        Constructor.

        Params:
            reader = FiberSelectReader instance to use for read requests
            writer = FiberSelectWriter instance to use for write requests
            fatal_error_exception = exception to be thrown if a fatal status
                code is received from the node

    ***************************************************************************/

    protected this ( FiberSelectReader reader, FiberSelectWriter writer,
        FatalErrorException fatal_error_exception )
    {
        super(reader, writer);

        this.fatal_error_exception = fatal_error_exception;
    }


    /***************************************************************************

        Fiber method. Stores the request parameters and handles the request,
        with the following steps:

            1. Send the server the data required for the request.
            2. Receive the status code from the server.
            3. If the status code is valid, then handle the request, calling the
               abstract handle__() method.
            4. If the status code is not valid, the derived class must decide
               whether it represents a fatal error, or a recoverable error. The
               statusActionSkip() method is called in the latter case, allowing
               the connection to be reused for the next command. The
               statusActionFatal() method is called for the former case, and
               an exception is thrown, causing the connection to be broken.

        Params:
            params = request parameters

        Throws:
            InvalidStatusException upon receiving a fatal status code

    ***************************************************************************/

    final public void handle ( IRequestParams params )
    {
        this.params_ = params;

        this.sendRequestData();

        super.writer.flush();

        this.receiveStatus();

        with ( StatusAction ) switch ( this.statusAction() )
        {
            case Handle:
                this.handle__();
                break;

            case Skip:
                this.statusActionSkip();
                break;

            case Fatal:
                this.statusActionFatal();
                throw this.fatal_error_exception(__FILE__, __LINE__);

            default:
                assert(false);
        }
    }


    /***************************************************************************

        Sends the server any data required by the request.

    ***************************************************************************/

    abstract protected void sendRequestData ( );


    /***************************************************************************

        Receives the status code from the server.

    ***************************************************************************/

    abstract protected void receiveStatus ( );


    /***************************************************************************

        Decides which action to take after receiving a status code from the
        server.

        Returns:
            action enum value (handle request / skip request / kill connection)

    ***************************************************************************/

    abstract protected StatusAction statusAction ( );


    /***************************************************************************

        Handles a request once the request data has been sent and a valid status
        has been received from the server.

    ***************************************************************************/

    abstract protected void handle__ ( );


    /***************************************************************************

        Handles a request once the request data has been sent and a non-ok
        (skip) status code has been received from the server.

        The base class does nothing, but sub-classes may wish to implement
        special behaviour here.

    ***************************************************************************/

    protected void statusActionSkip ( )
    {
    }


    /***************************************************************************

        Handles a request once the request data has been sent and an error
        (fatal) status code has been received from the server.

        The base class does nothing, but sub-classes may wish to implement
        special behaviour here.

    ***************************************************************************/

    protected void statusActionFatal ( )
    {
    }
}
