/*******************************************************************************

    Legacy protocol node connection handler template, including commands.

    Extends swarm.node.simplified.LegacyConnectionHandlerBase, adding actual
    request handling methods based on a set of command codes specified by the
    template argument.

    TODO: this module is a replacement of the deprecated
    swarm.node.connection.ConnectionHandler : ConnectionHandlerTemplate. The one
    difference is that this class has a simple reference to the node to which it
    belongs, rather than all node information being copied into a "connection
    setup params" object. When the deprecated module is removed, this module may
    be moved into its place.

    copyright:
        Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.node.simplified.LegacyConnectionHandlerTemplate;

import swarm.node.simplified.LegacyConnectionHandlerBase;

import ocean.transition;
import ocean.util.log.Log;
import swarm.Const;
import swarm.common.connection.CommandMixins;

/*******************************************************************************

    Legacy protocol connection handler base class template.

    An object pool of these connection handlers is contained in the
    SelectListener which is instantiated inside the node.

    A set of abstract methods are mixed into the class, one per command in the
    Commands tuple. The methods are name "handle" ~ Command.name. In this way,
    one handler method is required to be implemented in a deriving class per
    command which the node is expected to be able to handle.

    Template params:
        Commands = tuple of types defining a mapping between strings (command
            names) and values (command codes). Each member of the tuple is
            expected to have members called 'value', which should be an integer,
            and 'name', which should be a string

*******************************************************************************/

public abstract class LegacyConnectionHandlerTemplate ( Commands : ICommandCodes )
    : LegacyConnectionHandlerBase
{
    import ocean.time.StopWatch;

    /// Reuseable exception thrown when the command code read from the client
    /// is not supported (i.e. does not have a corresponding entry in
    /// this.requests).
    private Exception invalid_command_exception;

    /// Buffer used for formatting the description of the current command.
    protected mstring cmd_description;

    /***************************************************************************

        Constructor.

        Params:
            finalize_dg = user-specified finalizer, called when the connection
                is shut down
            node = struct containing everything needed to set up a connection

    ***************************************************************************/

    public this ( FinalizeDg finalize_dg, NodeBase node )
    {
        super(finalize_dg, node);

        this.invalid_command_exception = new Exception("Invalid command");
    }

    /***************************************************************************

        Called by IFiberConnectionHandler when a new connection is established
        by a client.

        Reads and handles the command sent by the client. If the command code is
        invalid then the connection must be killed in order to avoid reading in
        any subsequent data which the client may have sent and which will almost
        certainly be junk. This is achieved by the exception which is thrown in
        handleInvalidCommand(), below, and which is caught by the
        IFiberConnectionHandler.

    ***************************************************************************/

    override protected void handleCommand ( )
    {
        switch ( this.cmd )
        {
            mixin(CommandCases!(Commands));

            default:
                this.handleInvalidCommand();
        }
    }

    /// Enum defining the different stats tracking modes of `handleRequest()`.
    protected enum RequestStatsTracking
    {
        None,   /// No stats tracking
        Count,  /// Simple stats tracking (count of handled, active, max active)
        TimeAndCount /// Counted stats (as per Count) plus request timing stats
    }

    /***************************************************************************

        Calls the handle() method of the specified request and, in debug builds,
        measures the change in allocated memory between the beginning and the
        ending of the request. Increases in allocated memory are logged.

        At exit (after finished handling the request), the size of all buffers
        acquired from the shared resources pool during the request are checked.
        If any exceed 64K, a warning is logged.

        Template params:
            Resources = type of struct defining the types and names of resources
                which a request can acquire from the shared pools
            Acquired = type of class with getters for the resources acquired by
                a request. Assumed to be generated by instantiating the
                SharedResources_T template (see
                swarm.common.connection.ISharedResources) with Resources.
            stats = request stats tracking mode (see enum)

        Params:
            request = request handler to run
            acquired = resources acquired while handling the request
            rq_name = name of request for stats tracking (default to null)

    ***************************************************************************/

    protected void handleRequest ( Resources, Acquired,
        RequestStatsTracking stats = RequestStatsTracking.None )
        ( IRequest request, Acquired acquired, cstring rq_name = "" )
    {
        debug
        {
            const float Mb = 1024 * 1024;
            size_t used1, free1;
            GC.usage(used1, free1);

            scope ( exit )
            {
                size_t used2, free2;
                GC.usage(used2, free2);

                if ( used2 > used1 )
                {
                    log.info("Memory usage increased while handling command {} "
                        "(+{} bytes)", request.description(this.cmd_description),
                        used2 - used1);
                }
            }
        }

        scope ( exit )
        {
            // Log a warning if the length of any buffers acquired from the pool
            // of shared resources while handling this command exceed a sanity
            // limit afterwards.
            const warn_limit = 1024 * 64; // anything > 64K will be logged

            foreach ( i, F; typeof(Resources.tupleof) )
            {
                static if ( isArrayType!(F) )
                {
                    // FIXME_IN_D2: can't use `const` inside static foreach
                    // while it is converted in `static immutable`
                    mixin("auto buffer = acquired."
                        ~ FieldName!(i, Resources) ~ ";");
                    if ( buffer.length > warn_limit )
                    {
                        log.warn("Request resource '{}' grew to {} bytes while "
                            "handling {}", FieldName!(i, Resources), buffer.length,
                            request.description(this.cmd_description));
                    }
                }
            }
        }

        static if ( stats == RequestStatsTracking.Count )
        {
            assert(rq_name);
            this.node.request_stats.started(rq_name);
            scope ( exit ) this.node.request_stats.finished(rq_name);
        }
        else static if ( stats == RequestStatsTracking.TimeAndCount )
        {
            assert(rq_name);

            StopWatch timer;
            timer.start();

            this.node.request_stats.started(rq_name);
            scope ( exit ) this.node.request_stats.finished(rq_name,
                timer.microsec);
        }

        request.handle();
    }

    /// Mix-in protected abstract methods to handle individual commands.
    mixin(CommandMethods!(Commands));

    /***************************************************************************

        Called when an invalid command code is read from the connection. As the
        read buffer may now contain unknown data, the connection is simply
        broken by throwing an exception. The protected handleInvalidCommand_()
        is also called, allowing derived classes to add extra behaviour at this
        stage.

    ***************************************************************************/

    final protected void handleInvalidCommand ( )
    {
        this.handleInvalidCommand_();
        throw this.invalid_command_exception;
    }

    protected void handleInvalidCommand_ ( )
    {
    }
}

/*******************************************************************************

    Static module logger

*******************************************************************************/

private Logger log;
static this ( )
{
    log = Log.lookup("swarm.node.simplified.LegacyConnectionHandlerTemplate");
}

/*******************************************************************************

    Unit tests

*******************************************************************************/

unittest
{
    static class TestCommands : ICommandCodes
    {
        import ocean.core.Enum;

        mixin EnumBase!([
            "Put"[]:    1,
            "Get":      2,
            "Remove":   3
        ]);
    }

    alias LegacyConnectionHandlerTemplate!(TestCommands) Dummy;
    // FIXME: Dummy.handleRequest, as a template, is not being tested.
}
