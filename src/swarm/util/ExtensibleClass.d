/*******************************************************************************

    Mixin for extensible classes using plugins.

    A class can be given the ability to have its functionality extended by one
    or more plugins by mixing the template in this module into the class.

    Creating a class using a plugin architecture can sometimes be useful if a
    set of optional features is desired (each possibly with their own
    construction requirements), which cannot be arranged into a simple class
    hierarchy.

    Each plugin is a separately defined class, containing any data required for
    its operation, and providing one or more members which are mixed into the
    class being extended by the plugin. Plugin classes are required to contain
    a template named 'Extension', which will be mixed into the class being
    extended, and should contain any additional members required. Because
    everything in the Extension template is being mixed into the class being
    extended, it is able to declare or access other private members of the
    class.

    An extensible class (using the ExtensibleClass mixin in this module) owns an
    instance of each plugin specified. The additional members mixed into the
    class can then access these instances.

    Usage example:

    ---

        import ocean.io.Stdout;

        // A simple plugin which adds a method to a class to output a string to
        // the terminal.

        public class TracePlugin
        {
            // *****************************************************************
            // TracePlugin class members

            public TerminalOutput!(char) output;

            public this ( TerminalOutput!(char) output = Stdout )
            {
                this.output = output;
            }

            // *****************************************************************
            // Members to be added (mixed in) to the class being extended.

            // Methods inside the template can access an instance of TracePlugin
            // (owned by the class being extended). The name of the instance is
            // passed as the 'instance' template parameter as a string, and must
            // be mixed in wherever used.

            public template Extension ( istring instance )
            {
                public void trace ( cstring msg )
                {
                    mixin(instance).output.formatln(msg);
                }
            }
        }


        // A simple plugin which keeps a cumulative sum of numbers passed to it.
        // The plugin demonstrates the use of private members in the plugin
        // instance, accessed by setter/getter methods which are used by the
        // owning class (the class which the plugin is mixed into).

        public class SumPlugin
        {
            // *****************************************************************
            // SumPlugin class members

            private uint total_;

            public this ( uint initial = 0 )
            {
                this.total_ = initial;
            }

            public void add ( uint value )
            {
                this.total_ += value;
            }

            public uint total ( )
            {
                return this.total_;
            }

            // *****************************************************************
            // Members to be added (mixed in) to the class being extended.

            // Methods inside the template can access an instance of SumPlugin
            // (owned by the class being extended). The name of the instance is
            // passed as the 'instance' template parameter as a string, and must
            // be mixed in wherever used.

            public template Extension ( istring instance )
            {
                public void add ( uint value )
                {
                    mixin(instance).add(value);
                }

                public uint total ( )
                {
                    return mixin(instance).total();
                }
            }
        }


        import swarm.ExtensibleClass;

        // Template for an extensible class which can accept plugins.
        // An instance of each plugin specified in the template's tuple argument
        // must be passed to the class' constructor.

        public class MyExtensibleClass ( Plugins ... )
        {
            mixin ExtensibleClass!(Plugins);

            public this ( Plugins plugin_instances )
            {
                this.setPlugins(plugin_instances);
            }
        }


        // Creation of an instance of the extensible class with both plugins.
        alias MyExtensibleClass!(TracePlugin, SumPlugin) MyExtendedClass;

        auto ex = new MyExtendedClass(
            new TracePlugin(Stderr),
            new SumPlugin(23)
        );


        // Using the plugged-in members of the instance.

        ex.add(25);
        ex.trace("hello world");

    ---

    copyright:      Copyright (c) 2012-2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.

*******************************************************************************/

module swarm.util.ExtensibleClass;


/*******************************************************************************

    Imports

*******************************************************************************/

import ocean.transition;


/*******************************************************************************

    Extensible class mixin.

    Template params:
        Plugins = tuple of types of plugins

    For each type in the Plugins tuple, an instance of that type must be passed
    to the setPlugins() method (normally in the constructor of the class which
    this template is mixed into).

*******************************************************************************/

public template ExtensibleClass ( Plugins ... )
{
    import ocean.transition;

    static if ( Plugins.length )
    {
        /***********************************************************************

            Imports required by mixin. (Code which needs to be imported at the
            location where this template is mixed in, rather than inside this
            module itself.)

        ***********************************************************************/

        import ocean.core.Tuple : IndexOf;


        /***********************************************************************

            Iterates over the tuple of plugins and checks whether type T exists
            in the tuple. (Useful for static asserts checking whether a certain
            plugin exists.)

            Template params:
                T = type to search for in plugins tuple

            Evaluates to:
                true if T exists in plugins tuple, false otherwise

        ***********************************************************************/

        public template HasPlugin ( T )
        {
            const bool HasPlugin = IndexOf!(T, Plugins) < Plugins.length;
        }


        /***********************************************************************

            Plugin instances.

        ***********************************************************************/

        private Plugins plugin_instances;


        /***********************************************************************

            Iterates over the list of plugins and mixes in the extensions.

        ***********************************************************************/

        private template MixinPluginExtension ( T, istring instance_name )
        {
            mixin T.Extension!(instance_name);
        }

        private template MixinPluginExtensions ( size_t i = 0 )
        {
            static if ( i < Plugins.length )
            {
                mixin MixinPluginExtension!(Plugins[i], "this.plugin_instances["
                    ~ i.stringof ~ "]");
                mixin MixinPluginExtensions!(i + 1);
            }
        }

        mixin MixinPluginExtensions!();


        /***********************************************************************

            Sets the plugin instances.

            Params:
                plugin_instances = instance of each plugin

        ***********************************************************************/

        private void setPlugins ( Plugins plugin_instances )
        {
            this.plugin_instances = plugin_instances;
        }
    }
}
