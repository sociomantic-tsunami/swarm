/*******************************************************************************

    Extends `ocean.core.MessageFiber` by throwing in `suspend()` if an exception
    was passed to `resume()`.

    Copyright: Copyright (c) 2016-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.neo.util.MessageFiber;

/******************************************************************************

    Imports

 ******************************************************************************/

import ocean.transition;

import ocean.core.Thread : Fiber;

import ocean.core.Array: copy;

import ocean.core.SmartUnion;

import ocean.io.digest.Fnv1;

debug ( MessageFiber )
{
    import ocean.io.Stdout_tango;
    debug = MessageFiberToken;
}

debug ( MessageFiberToken )
{
    import ocean.io.digest.FirstName;
}

public class OceanMessageFiber
{
    import core.exception;

    /***************************************************************************

        Type of Exception/Throwable to rethrow if the fiber terminated
        because of unhandled instance.

    ***************************************************************************/

    version (D_Version2)
    {
        alias Error RethrowType;
    }
    else
    {
        alias AssertError RethrowType;
    }

    /**************************************************************************

        Token struct passed to suspend() and resume() methods in order to ensure
        that the fiber is resumed for the same reason as it was suspended. The
        token is constructed from a string, via the static opCall() method.

        Usage example:

        ---

            auto token = MessageFiber.Token("something_happened");

            fiber.suspend(token);

            // Later on, somewhere else
            fiber.resume(token);

        ---

     **************************************************************************/

    public struct Token
    {
        debug (MessageFiberToken) import ocean.text.convert.Format;

        /***********************************************************************

            String used to construct the token. In debug builds this is used for
            nice message output.

        ***********************************************************************/

        private debug (MessageFiberToken) istring str;

        /***********************************************************************

            Hash of string used to construct the token.

        ***********************************************************************/

        private hash_t hash;

        /***********************************************************************

            Constructs a token from a string (hashing the string).

            Params:
                s = string to construct token from

            Returns:
                token constructed from the passed string

        ***********************************************************************/

        public static Token opCall ( istring s )
        {
            Token token;
            token.hash = Fnv1a64(s);
            debug (MessageFiberToken) token.str = s;
            return token;
        }

        /***********************************************************************

            Constructs a token from a hash (copies the hash into the token).

            Params:
                h = hash to construct token from

            Returns:
                token constructed from the passed string

        ***********************************************************************/

        public static Token opCall ( hash_t h )
        {
            Token token;
            token.hash = h;
            debug (MessageFiberToken) token.str = Format("{}", h);
            return token;
        }
    }

    /**************************************************************************

        Message union

     **************************************************************************/

    private union Message_
    {
        int       num;
        void*     ptr;
        Object    obj;
        Exception exc;
    }

    public alias SmartUnion!(Message_) Message;

    /**************************************************************************

        Alias for fiber state

     **************************************************************************/

    public alias Fiber.State State;

    /**************************************************************************

        KilledException; thrown by suspend() when resumed by kill()

     **************************************************************************/

    static class KilledException : Exception
    {
        this ( )  {super("Fiber killed");}

        void set ( istring file, long line )
        {
            super.file = file;
            super.line = line;
        }
    }

    /**************************************************************************

        ResumedException; thrown by suspend() when resumed with the wrong
        identifier

     **************************************************************************/

    static class ResumeException : Exception
    {
        this ( )  {super("Resumed with invalid identifier!");}

        ResumeException set ( istring file, long line )
        {
            super.file = file;
            super.line = line;

            return this;
        }
    }

    /**************************************************************************

        Fiber instance

     **************************************************************************/

    private Fiber     fiber;

    /**************************************************************************

        Identifier

     **************************************************************************/

    private ulong           identifier;

    /**************************************************************************

        Message passed to resume() and returned by suspend()

     **************************************************************************/

    private Message suspend_ret_msg;

    /**************************************************************************

        Message passed to suspend() and returned by resume()

     **************************************************************************/

    private Message resume_ret_msg;

    /**************************************************************************

        KilledException instance

     **************************************************************************/

    private KilledException e_killed;

    /**************************************************************************

        ResumeException instance

     **************************************************************************/

    private ResumeException e_resume;

    /**************************************************************************

        "killed" flag, set by kill() and cleared by resume().

     **************************************************************************/

    private bool killed = false;

    /**************************************************************************

        Constructor

        Params:
            coroutine = fiber coroutine

     **************************************************************************/

    public this ( void delegate ( ) coroutine )
    {
        this.fiber = new Fiber(coroutine);
        this.e_killed = new KilledException;
        this.e_resume = new ResumeException;
        this.suspend_ret_msg.num = 0;
        this.resume_ret_msg.num = 0;

        debug(MessageFiberDump) addToList();

        debug (MessageFiber) Stdout.formatln("--FIBER {} CREATED (fiber ptr {}) --",
            FirstName(this), cast(void*) this.fiber).flush();
    }

    /**************************************************************************

        Constructor

        Params:
            coroutine = fiber coroutine
            sz      = fiber stack size

     **************************************************************************/

    public this ( void delegate ( ) coroutine, size_t sz )
    {
        this.fiber = new Fiber(coroutine, sz);
        this.e_killed = new KilledException;
        this.e_resume = new ResumeException;
        this.suspend_ret_msg.num = 0;
        this.resume_ret_msg.num = 0;

        debug(MessageFiberDump) addToList();

        debug (MessageFiber) Stdout.formatln("--FIBER {} CREATED (fiber ptr {}) --",
            FirstName(this), cast(void*) this.fiber).flush();
    }

    /**************************************************************************

        Destructor

        Removes the Fiber from the linked list and destroys its weak pointer

     **************************************************************************/

    debug(MessageFiberDump) ~this ( )
    {
        auto next = cast(MessageFiber) GC.weakPointerGet(next_fiber);
        auto prev = cast(MessageFiber) GC.weakPointerGet(prev_fiber);
        void* me;

        if ( next !is null )
        {
            if ( MessageFiber.last_fiber == next.prev_fiber )
            {
                MessageFiber.last_fiber = next_fiber;
            }

            me = next.prev_fiber;
            next.prev_fiber = prev_fiber;
        }

        if ( prev !is null )
        {
            me = prev.next_fiber;
            prev.next_fiber = next_fiber;
        }

        GC.weakPointerDestroy(me);
    }

    /**************************************************************************

        Adds this fiber to the linked list of Fibers

     **************************************************************************/

    debug(MessageFiberDump) void addToList ( )
    {
        auto me = GC.weakPointerCreate(this);

        if ( last_fiber !is null )
        {
            auto l = cast(MessageFiber) GC.weakPointerGet(MessageFiber.last_fiber);

            assert ( l !is null );

            l.next_fiber = me;
            prev_fiber = last_fiber;
        }

        last_fiber = me;
    }

    /**************************************************************************

        Starts the fiber coroutine and waits until it is suspended or finishes.

        Params:
            msg = message to be returned by the next suspend() call.

        Returns:
            When the fiber is suspended, the message passed to that suspend()
            call. It has always an active member, by default num but never exc.

        Throws:
            Exception if the fiber is suspended by suspendThrow().

        In:
            The fiber must not be running (but waiting or finished).

     **************************************************************************/

    public Message start ( Message msg = Message.init )
    in
    {
        assert (this.fiber.state != this.fiber.State.EXEC, "attempt to start an active fiber");
    }
    out (_msg_out)
    {
        auto msg_out = cast(Unqual!(typeof(_msg_out))) _msg_out;

        auto a = msg_out.active;
        assert (a);
        assert (a != a.exc);
    }
    body
    {
        debug (MessageFiber)
        {
            Stdout.formatln(
                "--FIBER {} (fiber ptr {}) STARTED (from fiber ptr {})",
                FirstName(this), cast(void*) this.fiber,
                cast(void*) Fiber.getThis()
            ).flush();
        }
     
        if (this.fiber.state == this.fiber.State.TERM)
        {
            this.fiber.reset();
            this.suspend_ret_msg.num = 0;
            this.resume_ret_msg.num = 0;
        }

        Token token;
        return this.resume(token, null, msg);
    }

    /**************************************************************************

        Suspends the fiber coroutine and waits until it is resumed or killed. If
        the active member of msg is msg.exc, exc will be thrown by the resuming
        start()/resume() call.

        Params:
            token = token expected to be passed to resume()
            identifier = reference to the object causing the suspend, use null
                         to not pass anything. The caller to resume must
                         pass the same object reference or else a ResumeException
                         will be thrown inside the fiber
            msg = message to be returned by the next start()/resume() call.

        Returns:
            the message passed to the resume() call which made this call resume.
            Its active member may be exc; for compatibility reasons this method
            does not throw in this case in contrast to resume().

        Throws:
            KilledException if the fiber is killed.

        In:
            The fiber must be running (not waiting or finished).
            If the active member of msg is msg.exc, it must not be null.

     **************************************************************************/

    public Message suspend ( Token token, Object identifier = null, Message msg = Message.init )
    in
    {
        assert (this.fiber.state == this.fiber.State.EXEC, "attempt to suspend an inactive fiber");
        with (msg) if (active == active.exc) assert (exc !is null);
    }
    out (_msg_out)
    {
        auto msg_out = cast(Unqual!(typeof(_msg_out))) _msg_out;
        assert(msg_out.active);
    }
    body
    {
        if (!msg.active)
        {
            msg.num = 0;
        }

        this.resume_ret_msg = msg;

        debug (MessageFiber)
        {
            Stdout.formatln(
                "--FIBER {} (fiber ptr {}) SUSPENDED (from fiber ptr {}) -- ({}:{} {})",
                FirstName(this), cast(void*) this.fiber,
                cast(void*) Fiber.getThis(), token.str, FirstName(identifier),
                identifier? identifier.classinfo.name : "{null identifier}"
            ).flush();
        }

        debug ( MessageFiberDump )
        {
            this.last = token;
            this.time = Clock.now().unix().seconds();
            this.suspender = identifier !is null ? identifier.classinfo.name : "";
        }

        this.suspend_();

        if ( this.identifier != this.createIdentifier(token.hash, identifier) )
        {
            throw this.e_resume.set(__FILE__, __LINE__);
        }

        assert(this.suspend_ret_msg.active);
        return this.suspend_ret_msg;
    }

    /**************************************************************************

        Suspends the fiber coroutine, makes the resuming start()/resume() call
        throw e and waits until the fiber is resumed or killed.

        Params:
            token = token expected to be passed to resume()
            e = Exception instance to be thrown by the next start()/resume()
            call.

        Returns:
            the message passed to the resume() call which made this call resume.
            Its active member may be exc; for compatibility reasons this method
            does not throw in this case in contrast to resume().

        Throws:
            KilledException if the fiber is killed.

        In:
            e must not be null and the fiber must be running (not waiting or
            finished).

     **************************************************************************/

    public Message suspend ( Token token, Exception e )
    in
    {
        assert (e !is null);
    }
    body
    {
        return this.suspend(token, null, Message(e));
    }

    /**************************************************************************

        Resumes the fiber coroutine and waits until it is suspended or
        terminates.

        Params:
            token = token expected to have been passed to suspend()
            identifier = reference to the object causing the resume, use null
                         to not pass anything. Must be the same reference
                         that was used in the suspend call, or else a
                         ResumeException will be thrown inside the fiber.
            msg = message to be returned by the next suspend() call.

        Returns:
            The message passed to the suspend() call which made this call
            resume.

        Throws:
            if an Exception instance was passed to the suspend() call which made
            this call be resumed, that Exception instance.

        In:
            The fiber must be waiting (not running or finished).

     **************************************************************************/

    public Message resume ( Token token, Object identifier = null, Message msg = Message.init )
    in
    {
        assert (this.fiber.state == this.fiber.State.HOLD, "attempt to resume a non-held fiber");
    }
    out (_msg_out)
    {
        auto msg_out = cast(Unqual!(typeof(_msg_out))) _msg_out;

        auto a = msg_out.active;
        assert (a);
        assert (a != a.exc);
    }
    body
    {
        if (!msg.active)
        {
            msg.num = 0;
        }

        this.identifier = this.createIdentifier(token.hash, identifier);

        debug (MessageFiber)
        {
            Stdout.formatln(
                "--FIBER {} (fiber ptr {}) RESUMED (from fiber ptr {}) -- ({}:{} {})",
                FirstName(this), cast(void*) this.fiber, cast(void*) Fiber.getThis(),
                token.str, FirstName(identifier),
                identifier? identifier.classinfo.name : "{null identifier}"
            ).flush();
        }

        this.suspend_ret_msg = msg;
        // If the fiber terminates with an unhandled exception, do not rethrow
        // that exception; otherwise, if `msg.exc` is active, this method will
        // throw `msg.exc` if it isn't caught by the fiber. However, this method
        // should throw only exceptions passed to the `suspend()` call that
        // continues the call of this method.
        version (D_Version2)
            auto throwable = this.fiber.call(Fiber.Rethrow.no);
        else
            auto throwable = this.fiber.call(false);

        // If the fiber terminated with an unhandled Error, rethrow it.
        if (cast(RethrowType)throwable)
        {
            throw throwable;
        }

        // To cover the case where the fiber is not suspended, but terminates,
        // we set a default message (the number 0).
        if ( this.fiber.state == this.fiber.State.TERM )
            this.resume_ret_msg.num = 0;
        assert(this.resume_ret_msg.active);

        if (this.resume_ret_msg.active == this.resume_ret_msg.active.exc)
        {
            throw this.resume_ret_msg.exc;
        }
        else
        {
            return this.resume_ret_msg;
        }
    }

    /**************************************************************************

        Kills the fiber coroutine. That is, resumes it and makes resume() throw
        a KilledException.

        Param:
            file = source file (passed to the exception)
            line = source code line (passed to the exception)

        Returns:
            When the fiber is suspended by suspend() or finishes.

        In:
            The fiber must be waiting (not running or finished).

     **************************************************************************/

    public void kill ( istring file = __FILE__, long line = __LINE__ )
    in
    {
        assert (this.fiber.state == this.fiber.State.HOLD, "attempt to kill a non-held fiber");
        assert (!this.killed);
    }
    body
    {
        debug (MessageFiber)
        {
            Stdout.formatln(
                "--FIBER {} (fiber ptr {}) KILLED (from fiber ptr {}) -- ({}:{})",
                FirstName(this), cast(void*) this.fiber,
                cast(void*) Fiber.getThis(), file, line
            ).flush();
        }

        this.killed = true;
        this.e_killed.set(file, line);

        version (D_Version2)
            auto throwable = this.fiber.call(Fiber.Rethrow.no);
        else
            auto throwable = this.fiber.call(false);

        // If the fiber terminated with an unhandled Error, rethrow it.
        if (cast(RethrowType)throwable)
        {
            throw throwable;
        }
    }

    /**************************************************************************

        Returns:
            true if the fiber is waiting or false otherwise.

     **************************************************************************/

    public bool waiting ( )
    {
        return this.fiber.state == this.fiber.State.HOLD;
    }

    /**************************************************************************

        Returns:
            true if the fiber is running or false otherwise.

     **************************************************************************/

    public bool running ( )
    {
        return this.fiber.state == this.fiber.State.EXEC;
    }

    /**************************************************************************

        Returns:
            true if the fiber is finished or false otherwise.

     **************************************************************************/

    public bool finished ( )
    {
        return this.fiber.state == this.fiber.State.TERM;
    }


    /**************************************************************************

        Resets the fiber

     **************************************************************************/

    public void reset ( )
    {
        this.fiber.reset();
    }

    /**************************************************************************

        Resets the fiber and change the coroutine

        Params:
            coroutine = fiber coroutine function

     **************************************************************************/

    public void reset ( void function() coroutine )
    {
        this.fiber.reset(coroutine);
    }

    /**************************************************************************

        Resets the fiber and change the coroutine

        Params:
            coroutine = fiber coroutine delegate

     **************************************************************************/

    public void reset ( void delegate() coroutine )
    {
        this.fiber.reset(coroutine);
    }


    /**************************************************************************

        Returns:
            fiber state

     **************************************************************************/

    public State state ( )
    {
        return this.fiber.state;
    }

    /**************************************************************************

        Suspends the fiber.

        Throws:
            suspendThrow() exception if pending

        In:
            The fiber must be running (not waiting or finished).

     **************************************************************************/

    private void suspend_ ( )
    in
    {
        assert (this.fiber.state == this.fiber.State.EXEC, "attempt to suspend a non-active fiber");
        assert (this.fiber is Fiber.getThis, "attempt to suspend fiber externally");
    }
    body
    {
        this.fiber.yield();

        if (this.killed)
        {
            this.killed = false;
            throw this.e_killed;
        }
    }

    /**************************************************************************

        Generates an identifier from a hash and an object reference.

        Params:
            hash = hash to generate identifier from
            obj = object reference to generate identifier from

        Returns:
            identifier based on provided hash and object reference (the two are
            XORed together)

     **************************************************************************/

    static private ulong createIdentifier ( hash_t hash, Object obj )
    {
        return hash ^ cast(ulong)cast(void*)obj;
    }
}


public class MessageFiber: OceanMessageFiber
{
    /**************************************************************************

        Constructor

        Params:
            coroutine = fiber coroutine

     **************************************************************************/

    public this ( void delegate ( ) coroutine ) { super(coroutine); }

    /**************************************************************************

        Constructor

        Params:
            routine = fiber coroutine
            sz      = fiber stack size

     **************************************************************************/

    public this ( void delegate ( ) coroutine, size_t sz ) { super(coroutine, sz); }

    /***************************************************************************

        Behaves like the overriddden method except that it throws if an
        exception was passed to the `resume()` call.

    ***************************************************************************/

    override public Message suspend ( Token token, Object identifier = null, Message msg = Message.init )
    {
        auto resume_msg = super.suspend(token, identifier, msg);

        if (resume_msg.active != resume_msg.active.exc)
            return resume_msg;
        else
            throw resume_msg.exc;
    }

    /// D2 requires explicit addition of base class methods into overload set
    alias OceanMessageFiber.suspend suspend;
}
