/*******************************************************************************

    Abstract fake node for integration with turtle's registry of env additions.

    Copyright:
        Copyright (c) 2015-2018 dunnhumby Germany GmbH. All rights reserved.

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module turtle.env.model.Node;

import ocean.meta.types.Qualifiers;
import ocean.text.convert.Formatter;
import turtle.env.model.Registry;
import ocean.core.Verify;

/*******************************************************************************

    Abstract fake node for integration with trutle's registry of env additions.

    Also includes methods for starting and stopping the fake node.

    Note: this class and derivatives are only used when running tests which need
    to *access* a node (the turtle env addition provides a fake node which can
    be inspected and modified by test cases). It is not relevant when running
    tests *on* a node implementation itself.

    Params:
        NodeType = type of the node server implementation
        id = name of the node type. Used for .nodes file name formatting

*******************************************************************************/


public class Cluster ( NodeType, istring id )
{
    import swarm.neo.AddrPort;
    import core.stdc.stdlib : rand;

    /// Used to prevent creating multiple fake nodes of the same type.
    static bool already_created = false;

    /// TODO indexed by legacy port
    protected Node!(NodeType)[] nodes;

    /***************************************************************************

        Constructor

    ***************************************************************************/

    public this ( )
    {
        verify(!already_created, "Can only have one " ~ id ~ " per turtle test app");
        already_created = true;
    }

    /// TODO
    public Node!(NodeType) addNode ( AddrPort addr )
    {
        auto node = new Node!(NodeType);
        node.start(addr);
        this.nodes ~= node;
        return node;
    }

    /// TODO
    public Node!(NodeType) randomNode ( )
    {
        verify(this.nodes.length > 0);
        return this.nodes[rand() % this.nodes.length];
    }

    /***************************************************************************

        Generate nodes files for the fake nodes. If the node supports the neo
        protocol then the neo nodes file will also be written.

        Params:
            directory = The directory the files will be written to.

    ***************************************************************************/

    public void genConfigFiles ( cstring directory )
    {
        shell("mkdir -p " ~ directory);

        auto legacyfile = new File(directory ~ "/" ~ id ~ ".nodes",
            File.WriteCreate);
        scope (exit) legacyfile.close();

        static if ( is(typeof(NodeType.neo_address)) )
        {
            auto neofile = new File(directory ~ "/" ~ id ~ ".neo.nodes",
                File.WriteCreate);
            scope (exit) neofile.close();
        }

        foreach ( addr, node; this.nodes )
        {
            auto node_address = format("{}.{}.{}.{}",
                addr.address_bytes[0],
                addr.address_bytes[1],
                addr.address_bytes[2],
                addr.address_bytes[3]);

            legacyfile.write(node_address ~ ":" ~
                Integer.toString(node.node_addrport.port));
            legacyfile.write("\n");

            static if ( is(typeof(NodeType.neo_address)) )
            {
                neofile.write(node_address ~ ":" ~
                    Integer.toString(node.neo_address.port));
                neofile.write("\n");
            }
        }
    }
}

/// TODO
public abstract class Node ( NodeType ) : ITurtleEnv
{
    import swarm.Const : NodeItem;
    import swarm.neo.AddrPort;
    import ocean.io.device.File;
    import ocean.core.Buffer;
    import turtle.env.Shell;
    import Integer = ocean.text.convert.Integer_tango;

    /// Enum defining the possibles states of the fake node service.
    private enum State
    {
        Init,
        Running,
        Stopped
    }

    /// State of the fake node service.
    private State state;

    /// Node service object. Instantiated when start() is called.
    protected NodeType node;

    /***************************************************************************

        Starts the fake node as part of test suite event loop. It will
        only terminate when whole test suite process dies.

        Params:
            addr = address to bind listening socket to
            port = port to bind listening socket to

    ***************************************************************************/

    public void start ( cstring addr = "127.0.0.1", ushort port = 0 )
    {
        verify(this.state == State.Init, "Node has already been started");

        AddrPort addrport;
        addrport.setAddress(addr.dup);
        addrport.port = port;
        this.node = this.createNode(addrport);
        this.state = State.Running;

        turtle_env_registry.register(this);
    }

    /***************************************************************************

        Restarts the fake node, reopening the listening socket on the same port
        determined in the initial call to start().

        Notes:
            1. Restarting the node *does not* clear any data in its storage
               engine. To do that, call reset().
            2. You must call stop() first, before calling restart().

    ***************************************************************************/

    public void restart ( )
    {
        verify(this.state == State.Stopped, "Node has not been stopped");

        this.node = this.createNode(this.node_addrport);
        this.state = State.Running;
    }

    /***************************************************************************

        Stops the fake node service. The node may be started again on the same
        port via restart().

    ***************************************************************************/

    final public void stop ( )
    {
        verify(this.state == State.Running, "Node is not running");

        this.stopImpl();
        this.state = State.Stopped;
    }

    /***************************************************************************

        Does hard reset of the node with terminating all persistent requests.
        Aliases to `clear` by default for backwards compatibility.

    ***************************************************************************/

    public void reset ( )
    {
        this.clear();
    }

    /***************************************************************************

        ITurtleEnv interface method implementation. Should not be called
        manually.

        Uses turtle env addition registry to stop tracking errors after all
        tests have finished. This is necessary because applications don't do
        clean connection shutdown when terminating, resulting in socker errors
        being reported on node side.

    ***************************************************************************/

    public void unregister ( )
    {
        this.log_errors(false);
    }

    /***************************************************************************

        Creates a fake node at the specified address/port.

        Params:
            node_addrport = address/port

    ***************************************************************************/

    abstract protected NodeType createNode ( AddrPort node_addrport );

    /***************************************************************************

        Returns:
            address/port on which node is listening

    ***************************************************************************/

    abstract public AddrPort node_addrport ( );

    /***************************************************************************

        Fake node service stop implementation.

    ***************************************************************************/

    abstract protected void stopImpl ( );

    /***************************************************************************

        Removes all data from the fake node service.

    ***************************************************************************/

    abstract public void clear ( );

    /***************************************************************************

        Suppresses/allows log output from the fake node if used version of node
        proto supports it.

        Params:
            log = true to log errors, false to stop logging errors

    ***************************************************************************/

    abstract public void log_errors ( bool log );
}
