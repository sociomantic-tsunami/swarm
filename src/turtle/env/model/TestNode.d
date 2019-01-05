/*******************************************************************************

    Abstract fake node for integration with turtle's registry of env additions.

    Provides the following features:
    * Integrates with turtle's env node registry.
    * Prevents construction of multiple instances. (A test should only need
      one.)
    * Methods to start, stop, and restart the node.
    * A method to generate legacy and neo config files for clients to connect
      with the node.

    To implement a fake node:
    * Derive from this class, providing your connection handler as the template
      argument.
    * Add a storage engine and methods to directly read from and write to it.
      (The application being tested should communicate with the fake node via
      the standard network protocol, but the test process itself can set up the
      data required by different test cases simply by writing directly into the
      fake node's storage.)
    * Implement the abstract `clear()` method, to remove all data.
    * Implement the other abstract methods of NodeBase (see
      swarm.node.model.NeoNode).

    Copyright:
        Copyright (c) 2015-2018 dunnhumby Germany GmbH. All rights reserved.

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module turtle.env.model.TestNode;

import ocean.transition;
import ocean.text.convert.Formatter;
import turtle.env.model.Registry;
import ocean.core.Verify;
import swarm.node.model.NeoNode;
import swarm.node.connection.ConnectionHandler;

/*******************************************************************************

    Abstract fake node for integration with turtle's registry of env additions.

    Also includes methods for starting and stopping the fake node.

    Note: this class and derivatives are only used when running tests which need
    to *access* a node (the turtle env addition provides a fake node that can
    be inspected and modified by test cases). It is not relevant when running
    tests *on* a node implementation itself.

    Params:
        ConnHandler = node connection handler type

*******************************************************************************/

public abstract class TestNode ( ConnHandler : ISwarmConnectionHandler )
    : NodeBase!(ConnHandler), ITurtleEnv
{
    import swarm.neo.AddrPort;
    import ocean.io.device.File;
    import ocean.core.Buffer;
    import ocean.net.server.SelectListener;
    import ocean.task.Scheduler;
    import ocean.task.Task;
    import turtle.env.Shell;
    import Integer = ocean.text.convert.Integer_tango;
    import ocean.io.select.client.model.ISelectClient : IAdvancedSelectClient;
    import ocean.net.server.connection.IConnectionHandlerInfo;
    import ocean.io.select.protocol.generic.ErrnoIOException;
    import ocean.util.log.Logger;

    /// Enum defining the possibles states of the fake node service.
    private enum State
    {
        Init,
        Running,
        Stopped
    }

    /// State of the fake node service.
    private State state;

    /// Used to prevent creating multiple fake nodes of the same type.
    static bool already_created = false;

    /// Flag indicating that unhandled exceptions from the node must be printed
    /// in test suite trace.
    private bool log_errors = true;

    /// Logger for turtle nodes of this type.
    private Logger log;

    /***************************************************************************

        Constructor

        Params:
            node = node addres & port
            neo_port = port of neo listener (same address as above)
            conn_setup_params = connection handler constructor arguments
            options = options for the neo node and connection handlers
            backlog = (see ISelectListener ctor)

    ***************************************************************************/

    public this ( AddrPort node, ushort neo_port,
        ConnectionSetupParams conn_setup_params, Options options, int backlog )
    {
        verify(!already_created, "Can only have one " ~ idup(this.id) ~
            " per turtle test app");
        already_created = true;

        auto addr_buf = new char[AddrPort.AddrBufLength];
        super(node.asNodeItem(addr_buf), neo_port, conn_setup_params, options,
            backlog);
        this.error_callback = &this.onError;

        this.log = Log.lookup(this.id);
    }

    /***************************************************************************

        Starts the fake node as part of test suite event loop. It will
        only terminate when whole test suite process dies.

    ***************************************************************************/

    public void start ( )
    {
        verify(this.state == State.Init, "Node has already been started");
        this.state = State.Running;
        turtle_env_registry.register(this);

        this.register(theScheduler.epoll);
        if ( Task.getThis() )
            theScheduler.processEvents();
    }

    /***************************************************************************

        Restarts the fake node, reopening the listening socket on the same port
        determined in the initial call to start().

        Note: Restarting the node *does not* clear any data in its storage
        engine. To do that, consult the methods of the derived class.

    ***************************************************************************/

    public void restart ( )
    {
        with ( State ) switch ( this.state )
        {
            case Stopped:
                break;
            case Running:
                this.stop();
                break;
            case Init:
            default:
                verify(false, "Node has not been started yet");
                break;
        }

        this.restartListeners();
        this.register(theScheduler.epoll);
        turtle_env_registry.register(this);

        this.state = State.Running;
    }

    /***************************************************************************

        Stops the fake node service. The node may be started again on the same
        port via restart().

    ***************************************************************************/

    final public void stop ( )
    {
        verify(this.state == State.Running, "Node is not running");

        this.stopListeners(theScheduler.epoll);
        this.shutdown();
        this.unregister(); // Remove from turtle nodes registry
        this.state = State.Stopped;
    }

    /***************************************************************************

        Generate nodes files for the fake nodes. If the node supports the neo
        protocol then the neo nodes file will also be written. The files are
        named:
        * this.id ~ ".nodes"
        * this.id ~ ".neo.nodes"

        Params:
            directory = The directory the files will be written to.

    ***************************************************************************/

    public void genConfigFiles ( cstring directory )
    {
        shell("mkdir -p " ~ directory);

        auto legacyfile = new File(directory ~ "/" ~ this.id ~ ".nodes",
            File.WriteCreate);
        scope (exit) legacyfile.close();

        legacyfile.write(this.node_item.Address ~ ":" ~
            Integer.toString(this.node_item.Port));
        legacyfile.write("\n");

        auto neofile = new File(directory ~ "/" ~ this.id ~ ".neo.nodes",
            File.WriteCreate);
        scope (exit) neofile.close();

        neofile.write(this.node_item.Address ~ ":" ~
            Integer.toString(this.neo_address.port));
        neofile.write("\n");
    }

    /***************************************************************************

        ITurtleEnv interface method implementation. Should not be called
        manually.

        Uses turtle env addition registry to stop tracking errors after all
        tests have finished. This is necessary because applications don't do
        clean connection shutdown when terminating, resulting in socket errors
        being reported on node side.

    ***************************************************************************/

    public void unregister ( )
    {
        this.log_errors = false;
    }

    /***************************************************************************

        Log errors, if logging is enabled.

    ***************************************************************************/

    private void onError ( Exception exception, IAdvancedSelectClient.Event,
        IConnectionHandlerInfo )
    {
        if (!this.log_errors)
            return;

        this.log.warn("Ignoring exception: {} ({}:{})",
            exception.message(), exception.file, exception.line);
    }
}
