/*******************************************************************************

    Set of listeners which have requested to be notified when new data arrives
    in a storage channel.

    TODO: could be extended to also notify the listener(s) of data being removed
    from the channel.

    copyright:      Copyright (c) 2011-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

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
        Deletion,   // a record has been deleted
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

    protected struct ListenerSet
    {
        import swarm.neo.util.TreeMap;
        import ocean.util.container.ebtree.c.eb64tree;

        /***********************************************************************

            The registered listeners sorted by object address.

        ***********************************************************************/

        private TreeMap!() listeners;

        /***********************************************************************

            The current listener, used by `next`.

        ***********************************************************************/

        private eb64_node* current = null;

        /***********************************************************************

            The number of registered listeners.

        ***********************************************************************/

        private uint n = 0;

        /***********************************************************************

            Adds a listener to the set.

            Params:
                listener = listener to add to set

        ***********************************************************************/

        public void add ( Listener listener )
        {
            bool added;
            (&this).listeners.put(cast(ulong)cast(void*)listener, added);
            (&this).n += added;
        }


        /***********************************************************************

            Gets the next registered listener from the set, in a round robin.

            Returns:
                next listener in the set (or null if the set is empty)

        ***********************************************************************/

        public Listener next ( )
        {
            if ((&this).current is null)
                (&this).current = (&this).listeners.getBoundary!()();

            if ((&this).current !is null)
            {
                auto listener = cast(Listener)cast(void*)((&this).current.key);
                (&this).current = (&this).current.next;
                return listener;
            }
            else
                return null;
        }


        /***********************************************************************

            Removes the given listener from the set

            Returns:
                removed listener or null if it wasn't found

        ***********************************************************************/

        public Listener remove ( Listener l )
        {
            if (auto node = (cast(ulong)cast(void*)l) in (&this).listeners)
            {
                if (node is (&this).current)
                    (&this).current = null;
                (&this).listeners.remove(*node);
                (&this).n--;
                return l;
            }
            else
                return null;
        }


        /***********************************************************************

            Returns:
                number of waiting listeners

        ***********************************************************************/

        public size_t length ( )
        {
            return (&this).n;
        }


        /***********************************************************************

            OpApply iterator

        ***********************************************************************/

        public int opApply ( scope int delegate ( ref Listener listener ) dg )
        {
            return (&this).listeners.opApply(
                (ref eb64_node node)
                {
                    auto listener = cast(Listener)cast(void*)node.key;
                    return dg(listener);
                }
            );
        }


        /***********************************************************************

            Returns:
                true if there are listeners waiting or false if not.

        ***********************************************************************/

        public bool is_empty ( )
        {
            return (&this).listeners.is_empty;
        }
    }


    /***************************************************************************

        Set of listeners

    ***************************************************************************/

    protected ListenerSet listeners;


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
        if ( !this.listeners.is_empty )
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
        assert(!this.listeners.is_empty, "trigger_() called with no listeners registered");
    }
    body
    {
        foreach ( listener; this.listeners )
        {
            listener.trigger(code, data);
        }
    }


    /***************************************************************************

        Each element in `this.listeners` is a `malloc`-allocated object so they
        need to be removed to be deleted when this instance is garbage-
        collected. This is safe because `this.listeners` does not refer to any
        GC-allocated object.

    ***************************************************************************/

    ~this ( )
    {
        foreach (ref node; this.listeners)
        {
            this.listeners.remove(node);
        }
    }
}

version (UnitTest) import ocean.core.Test;

unittest
{
    // Create a few template instances to make sure they compile. Only Instance1
    // is used in further tests.
    alias IListeners!(uint) Instance1;
    alias IListeners!(uint, mstring) Instance2;

    static class Listener: Instance1.Listener
    {
        override void trigger ( Code code, uint data ) { }
    }

    Instance1.ListenerSet liset;

    // Tests the non-empty `liset`.
    // `listeners` should contain the elements that are expected in `liset` in
    // order; that is, unique elements sorted ascendingly by object pointer.
    // `name` is the name of the test.
    void testListenerSet ( istring name, Listener[] listeners ... )
    in
    {
        assert(listeners.length);
        foreach (i, listener; listeners[1 .. $])
            assert(cast(void*)listeners[i] < cast(void*)listener,
            "wrong order of listeners");
    }
    body
    {
        auto test = new NamedTest(name);

        test.test(!liset.is_empty);
        test.test!("==")(liset.length, listeners.length);

        // Call `liset.next` until it returns `listeners[$ - 1]`. This should
        // take at most `listeners.length` calls of `liset.next`.
        for (uint i = 0; liset.next !is listeners[$ - 1]; i++)
            test.test!("<")(i, listeners.length);

        // In the first cycle of this loop `liset.next` should wrap around and
        // return `listeners[0]`; in the following cycles it should return the
        // expected listeners in order.
        foreach (listener; listeners)
            test.test!("is")(liset.next, listener);

        // Again `liset.next` should wrap around and return `listeners[0]`.
        test.test!("is")(liset.next, listeners[0]);
    }

    scope lis1 = new Listener,
          lis2 = new Listener,
          lis3 = new Listener;

    // Make sure the order of addresses is lis1, lis2, lis3.
    test!("<")(cast(void*)lis1, cast(void*)lis2);
    test!("<")(cast(void*)lis2, cast(void*)lis3);

    // Empty set of listeners.
    test!("==")(liset.length, 0);
    test(liset.next is null);
    test(liset.is_empty);
    foreach (lis; liset)
        test(false);

    liset.add(lis2);
    testListenerSet("added lis2", lis2);

    liset.add(lis1);
    testListenerSet("added lis1", lis1, lis2);

    liset.add(lis3);
    testListenerSet("added lis3", lis1, lis2, lis3);

    // Remove lis1 during iteration.
    uint i = 0;
    foreach (lis; liset)
    {
        switch (i++)
        {
            case 0:
                test!("is")(lis, lis1);
                test!("is")(liset.remove(lis), lis);
                break;
            case 1: test!("is")(lis, lis2); break;
            case 2: test!("is")(lis, lis3); break;
            default: test(false);
        }
    }
    testListenerSet("removed lis2", lis2, lis3);

    // Attempt to remove lis1, which is not in the set.
    test(liset.remove(lis1) is null);
    testListenerSet("attempted to remove lis1", lis2, lis3);

    // Add lis3, which is already in the set, so the set shouldn't change.
    liset.add(lis3);
    testListenerSet("attempted to add duplicate lis3", lis2, lis3);

    // Remove lis2, `liset.next` should move to lis3.
    test!("is")(liset.remove(lis2), lis2);
    test!("is")(liset.next, lis3);
    testListenerSet("removed lis2", lis3);

    // Remove lis3, the last listener in the set.
    test!("is")(liset.remove(lis3), lis3);
    test!("==")(liset.length, 0);
    test(liset.next is null);
    test(liset.is_empty);
}
