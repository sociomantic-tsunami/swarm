/*******************************************************************************

    CTFE functions for mixing core state machine functionality into an
    aggregate.

    Usage example:
        See documented unittest of genStateMachine().

    Copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.util.StateMachine;

/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.transition;

version ( UnitTest )
{
    import ocean.core.Test;
}

/*******************************************************************************

    Formats a string containing code for the core functionality of a state
    machine with the specified states. The resulting string should be mixed-in
    to a suitable aggregate.

    The following facilities are provided by the generated code:
        1. An enum, `State`, containing all of the specified states as values,
           plus the automatically added Exit state; `State.Exit` is 0.
        2. A `run()` method, which sets the state machine into the specified
           initial state and starts it running, calling the per-state methods
           (see below) in a loop until one of them returns `State.Exit`.

    The location where the code is mixed-in is expected to contain:
        * One method per state, named as follows: `state<state_name>`. The
          methods must return a `State` and accept no arguments.

    The location where the code is mixed-in is may contain a `beforeState`
    method which accepts no arguments and is called on a state change, before
    the `state*` method is called or, if changing to the Exit state, `run()`
    returns.

    Params:
        states = list of names of states which the state machine should handle.
            The state Exit, which ends the state machine, is added automatically

    Returns:
        string containing code to be mixed-in

*******************************************************************************/

public istring genStateMachine ( istring[] states )
{
    assert(states.length);

    return
        genEnum(states) ~
        "private State state;" ~
        "public void run ( State init_state ) {" ~
            "this.state = init_state; do {" ~
                "static if(is(typeof({this.beforeState();}))) this.beforeState(); " ~
                genSwitch(states) ~
            "} while(this.state != State.Exit);" ~
        "static if(is(typeof({this.beforeState();}))) this.beforeState(); " ~
        "}";
}

/// Usage example
unittest
{
    // Container for the state machine enum, run() function, and state functions
    struct SM
    {
        // List of strings defining the names of the possible states
        // (the state Exit is added automatically)
        const istring[] states = ["One", "Two", "Three"];

        // Mixin the output of genStateMachine(), with your list of states
        mixin(genStateMachine(states));

        // Define one function per state. The state functions should be named
        // the same as the states, with the word `state` prepended.
        // Each function must return the next state to transition to. In this
        // simple example, each state leads on to the next, but a real world
        // usage will likely have loops, branches, etc.
        State stateOne ( )
        {
            return State.Two;
        }

        State stateTwo ( )
        {
            return State.Three;
        }

        State stateThree ( )
        {
            // Returning State.Exit causes the state machine to stop running.
            return State.Exit;
        }
    }

    SM sm;

    // Call the state machine's run() method with the initial state to start it
    // running. It will run until a state function returns State.Exit.
    sm.run(SM.State.One);
}

// Test the output of genStateMachine()
unittest
{
    test!("==")(genStateMachine(["One", "Two", "Three"]),
        "private enum State:uint {Exit,One,Two,Three}" ~
        "private State state;" ~
        "public void run ( State init_state ) {" ~
            "this.state = init_state; do {" ~
                "static if(is(typeof({this.beforeState();}))) this.beforeState(); " ~
                "switch ( this.state ) {" ~
                "case State.One: this.state = cast(State)this.stateOne(); break;" ~
                "case State.Two: this.state = cast(State)this.stateTwo(); break;" ~
                "case State.Three: this.state = cast(State)this.stateThree(); break;" ~
                "default: assert(false);}" ~
            "} while(this.state != State.Exit);" ~
            "static if(is(typeof({this.beforeState();}))) this.beforeState(); " ~
        "}");
}

// Test a real struct using the state machine mixin
unittest
{
    struct SM
    {
        private uint state_count;

        mixin(genStateMachine(["One", "Two", "Three"]));

        State stateOne ( )
        {
            test!("==")(this.state, State.One);
            this.state_count++;
            test!("==")(this.state_count, 1);
            return State.Two;
        }

        State stateTwo ( )
        {
            test!("==")(this.state, State.Two);
            this.state_count++;
            test!("==")(this.state_count, 2);
            return State.Three;
        }

        State stateThree ( )
        {
            test!("==")(this.state, State.Three);
            this.state_count++;
            test!("==")(this.state_count, 3);
            return State.Exit;
        }
    }

    SM sm;
    sm.run(SM.State.One);
    test!("==")(sm.state_count, 3);
    test!("==")(sm.state, SM.State.Exit);
}

/*******************************************************************************

    Formats a string containing code for the `State` enum of a state machine.

    Params:
        states = list of names of states which the enum should contain

    Returns:
        string containing code to be mixed-in

*******************************************************************************/

private istring genEnum ( istring[] states )
{
    assert(states.length);

    istring ret;
    ret ~= "private enum State:uint {Exit";
    foreach ( s; states )
    {
        ret ~= "," ~ s;
    }
    ret ~= "}";
    return ret;
}

// Test the output of genEnum()
unittest
{
    test!("==")(genEnum(["One", "Two", "Three"]),
        "private enum State:uint {Exit,One,Two,Three}");
}

/*******************************************************************************

    Formats a string containing code for a switch statement with one case per
    specified state of the state machine. Each case calls the method associated
    with the state (e.g. `case State.Example` will call `this.stateExample()`).

    Params:
        states = list of names of states (i.e. cases) which the switch statement
            should handle

    Returns:
        string containing code to be mixed-in

*******************************************************************************/

private istring genSwitch ( istring[] states )
{
    istring ret;
    ret ~= "switch ( this.state ) {";
    foreach ( s; states )
    {
        ret ~= "case State." ~ s ~ ": this.state = cast(State)this.state" ~ s ~ "(); break;";
    }
    ret ~= "default: assert(false);}";
    return ret;
}

// Test the output of genSwitch()
unittest
{
    test!("==")(genSwitch(["One", "Two", "Three"]),
        "switch ( this.state ) {"
        ~ "case State.One: this.state = cast(State)this.stateOne(); break;"
        ~ "case State.Two: this.state = cast(State)this.stateTwo(); break;"
        ~ "case State.Three: this.state = cast(State)this.stateThree(); break;"
        ~ "default: assert(false);}");
}
