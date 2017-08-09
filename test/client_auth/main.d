/*******************************************************************************

    Test for loading client auth name/key from a file.

    Copyright:
        Copyright (c) 2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module test.client_auth.main;

import test.neo.client.Client;

import swarm.neo.authentication.CredentialsFile;

import ocean.transition;
import ocean.util.test.DirectorySandbox;
import ocean.core.Test;
import ocean.io.device.File;
import ocean.io.select.EpollSelectDispatcher;

void main ( )
{
    // Create temporary sandbox directory to write files to.
    auto sandbox = DirectorySandbox.create();
    scope (exit) sandbox.remove();

    // Helper function to write a credentials file and instantiate a client to
    // read it.
    void loadCredentials ( cstring credentials )
    {
        auto file = new File("credentials", File.ReadWriteCreate);
        file.write(credentials);
        file.close();

        void connNotifier ( Client.Neo.ConnNotification ) { }

        auto client = new Client(new EpollSelectDispatcher, "credentials",
            "127.0.0.1", 10_000, &connNotifier);
    }

    // Valid credentials file.
    loadCredentials("test:0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000");

    // Credentials file with invalid key (too short).
    testThrown!(CredentialsParseException)(
        loadCredentials("test:X0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")
    );

    // Credentials file with invalid key (too long).
    testThrown!(CredentialsParseException)(
        loadCredentials("test:000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")
    );

    // Credentials file with mutliple lines.
    testThrown!(Exception)(
        loadCredentials("test:0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000\ntest2:0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")
    );
}
