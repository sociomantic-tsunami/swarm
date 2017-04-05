/*******************************************************************************

    Set of listeners which have requested to be notified when new data arrives
    in a storage channel.

    TODO: could be extended to also notify the listener(s) of data being removed
    from the channel.

    copyright:      Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.node.storage.listeners.Listeners;



/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.util.container.map.Set;

import ocean.util.container.map.model.StandardHash;

import ocean.io.select.client.FiberSelectEvent;

import ocean.core.array.Mutation : moveToEnd;

import ocean.transition;

/*******************************************************************************

    Listener root interface, defines the Code enumerator.

*******************************************************************************/

public interface IListener
{
    /***************************************************************************

        Listener trigger event code.

        Code.None is used for assertions.

    ***************************************************************************/

    enum Code : uint
    {
        None = 0,
        DataReady,  // a record is ready for reading
        Flush,      // the write buffer should be flushed
        Finish      // the listener should stop listening (e.g. in the case when
                    // the listen source is about to disappear
    }
}



/*******************************************************************************

    Listener interface template. Should be implemented by anything which wants
    to be notified when data is received.

    Template params:
        Data = tuple of types to be passed to each listener when a trigger
            occurs

*******************************************************************************/

public interface IListenerTemplate ( Data ... ) : IListener
{
    public void trigger ( Code code, Data data );
}



/*******************************************************************************

    Listeners set base class template. Maintains a set of listeners (classes
    which implement IListenerTemplate) which are to be notified when various
    events occur, via the public trigger() method.

    The actual notification of the listeners is done in the protected trigger_()
    method, which contains a base implementation which triggers all registered
    listeners. If different behaviour is desired at this stage (e.g. notify all
    listeners / notify just one listener / etc), the class can be derived from
    and this method overridden.

    Template params:
        Data = tuple of types to be passed to each listener when a trigger
            occurs

*******************************************************************************/

public class IListeners ( Data ... )
{
    /***************************************************************************

        Listener alias

    ***************************************************************************/

    public alias IListenerTemplate!(Data) Listener;


    /***************************************************************************

        Set of listeners and methods for notifying them of various events.

    ***************************************************************************/

    protected static class ListenerSet
    {
        /***********************************************************************

            List of waiting listeners

        ***********************************************************************/

        private Listener[] listeners;


        /***********************************************************************

            Index of current listener. Used by the next() method.

        ***********************************************************************/

        private size_t current;


        /***********************************************************************

            Set of waiting listeners (for fast lookup to tell whether a listener
            is already registered or not)

        ***********************************************************************/

        private static class ListenersSet : Set!(Listener)
        {
            /*******************************************************************

                Constructor, sets the number of buckets to n * load_factor. n is
                the estimated number of listeners per channel, and load_factor
                is the desired ratio of buckets to set elements. Both these
                values are defined as constants in the constructor.

                TODO: would it be beneficial to be able to configure these
                constants?

                Params:
                    load_factor = load factor

            *******************************************************************/

            public this ( )
            {
                const listeners_estimate = 50;
                const float load_factor = 0.75;

                super(listeners_estimate, load_factor);
            }


            /*******************************************************************

                Calculates the hash value for a listener. The listener reference
                is simply passed to the hashing function as a ubyte[].

                Params:
                    listener = listener to hash

                Returns:
                    the hash value that corresponds to listener.

            *******************************************************************/

            override public hash_t toHash ( Listener listener )
            {
                return StandardHash.toHash(
                    (cast(ubyte*)&listener)[0..listener.sizeof]);
            }
        }

        private ListenersSet listeners_set;


        /***********************************************************************

            Asserts that the list and the set always have the same number of
            listeners.

        ***********************************************************************/

        invariant ( )
        {
            auto _this = cast(ListenerSet) this;
            assert(
                _this.listeners.length == _this.listeners_set.bucket_info.length,
                typeof(this).stringof ~ ".invariant: listeners set & list are not the same length"
            );
        }


        /***********************************************************************

            Constructor

        ***********************************************************************/

        public this ( )
        {
            this.listeners_set = new ListenersSet;
        }


        /***********************************************************************

            Pushes a listener to the set.

            Params:
                listener = listener to add to set

        ***********************************************************************/

        public void add ( Listener listener )
        {
            if ( !(listener in this.listeners_set) )
            {
                this.listeners ~= listener;
                this.listeners_set.put(listener);
            }
        }


        /***********************************************************************

            Gets the next registered listener from the set, in a round robin.

            Returns:
                next listener in the set (or null if the set is empty)

        ***********************************************************************/

        public Listener next ( )
        {
            scope ( exit )
            {
                // Increment index and wrap.
                if ( ++this.current >= this.listeners.length )
                {
                    this.current = 0;
                }
            }

            if ( this.listeners.length == 0 )
            {
                return null;
            }

            // Ensure index is within bounds.
            if ( this.current >= this.listeners.length )
            {
                this.current = 0;
            }

            return this.listeners[this.current];
        }


        /***********************************************************************

            Removes the given listener from the set

            Returns:
                removed listener or null if it wasn't found

        ***********************************************************************/

        public Listener remove ( Listener l )
        {
            if ( this.listeners.length == 0 )
            {
                return null;
            }

            if ( this.listeners_set.remove(l) )
            {
                this.listeners.length = .moveToEnd(this.listeners, l);
                enableStomping(this.listeners);

                return l;
            }

            return null;
        }


        /***********************************************************************

            Returns:
                number of waiting listeners

        ***********************************************************************/

        public size_t length ( )
        {
            return this.listeners.length;
        }


        /***********************************************************************

            OpApply iterator

        ***********************************************************************/

        public int opApply ( int delegate ( ref Listener listener ) dg )
        {
           int result = 0;

           foreach ( l; this.listeners )
           {
               result = dg(l);

               if (result) break;
           }

           return result;
        }
    }


    /***************************************************************************

        Set of listeners

    ***************************************************************************/

    protected ListenerSet listeners;


    /***************************************************************************

        Constructor

    ***************************************************************************/

    public this ( )
    {
        this.listeners = new ListenerSet;
    }


    /***************************************************************************

        Registers a listener with an event to trigger when data is ready.

        Params:
            listener = listener to register

    ***************************************************************************/

    public void register ( Listener listener )
    {
        this.listeners.add(listener);
    }


    /***************************************************************************

        Removes the given listener from the set

        Params:
            listener = listener to unregister

        Returns:
            removed listener or null if it wasn't found

    ***************************************************************************/

    public Listener unregister ( Listener listener )
    {
        return this.listeners.remove(listener);
    }


    /***************************************************************************

        Should be called when one or more listeners (if registered) should be
        triggered. Calls the trigger_() method if at least one listener is
        registered.

        Params:
            code = code to trigger with (see enum in IListener, above)
            data = data to trigger with (see class template params)

    ***************************************************************************/

    final public void trigger ( Listener.Code code, Data data )
    {
        if ( this.listeners.length )
        {
            this.trigger_(code, data);
        }
    }


    /***************************************************************************

        Called when a trigger occurs and one or more listeners are registered.
        All registered listeners are triggered.

        Params:
            code = code to trigger with (see enum in IListener, above)
            data = data to trigger with (see class template params)

    ***************************************************************************/

    protected void trigger_ ( Listener.Code code, Data data )
    in
    {
        assert(this.listeners.length, "trigger_() called with no listeners registered");
    }
    body
    {
        foreach ( listener; this.listeners )
        {
            listener.trigger(code, data);
        }
    }
}

unittest
{
    alias IListeners!(uint) Instance1;
    alias IListeners!(uint, mstring) Instance2;
}
