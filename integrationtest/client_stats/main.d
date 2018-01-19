/*******************************************************************************

    Test for registering client stats log with an app's reopenable files ext.

    deprecated code for pre-v3.6.0 ocean can be removed once the ocean submodule
    is updated.

    Copyright:
        Copyright (c) 2018 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module integrationtest.client_stats.main;

import ocean.transition;
import ocean.core.Test;
import ocean.core.VersionCheck;
import ocean.io.device.File;
import ocean.io.select.EpollSelectDispatcher;
import ocean.util.app.Application;
import ocean.util.app.ext.ReopenableFilesExt;
import ocean.util.test.DirectorySandbox;

import swarm.util.log.ClientStats;

version ( UnitTest ) {}
else void main ( )
{
    // Create temporary sandbox directory to write files to.
    auto sandbox = DirectorySandbox.create();
    scope (exit) sandbox.remove();

    // Test that constructing a ClientStats with the ctor that accepts an
    // IApplication successfully registers the log with the application's
    // reopenable files extension.
    auto app = new App;
    auto client_stats = new ClientStats(app, new EpollSelectDispatcher,
        "client_stats.log");

    static if ( hasFeaturesFrom!("ocean", 3, 6) )
    {
        test(app.rof_ext.reopenFile("client_stats.log"));
    }
    else
    {
        test!("==")(app.rof_ext.files.length, 1);
        test!("==")(app.rof_ext.files[0].toString(), "client_stats.log");
    }
}

static if ( !hasFeaturesFrom!("ocean", 3, 6) )
{
    // Extend ReopenableFilesExt to work around the fact that the list of
    // registered files is private.
    class TestReopenableFilesExt : ReopenableFilesExt
    {
        File[] files;

        override public void register ( File file )
        {
            this.files ~= file;
            super.register(file);
        }
    }
}

// Simple app class with a reopenable files extension.
class App : Application
{
    static if ( hasFeaturesFrom!("ocean", 3, 6) )
        alias ReopenableFilesExt ROFExt;
    else
        alias TestReopenableFilesExt ROFExt;

    ROFExt rof_ext;

    this ( )
    {
        super("test", "test");
        this.rof_ext = new ROFExt;
        this.registerExtension(this.rof_ext);
    }

    override protected int run ( istring[] args )
    {
        return 0;
    }
}
