/*******************************************************************************

    Test for loading client config, including nodes and auth name/key from disk.

    Copyright:
        Copyright (c) 2017 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module integrationtest.client_auth.main;

import integrationtest.neo.client.Client;

import swarm.neo.authentication.CredentialsFile;

import ocean.transition;
import ocean.util.test.DirectorySandbox;
import ocean.core.Test;
import ocean.io.device.File;
import ocean.io.select.EpollSelectDispatcher;
import Config = ocean.util.config.ConfigFiller;
import ocean.util.config.ConfigParser;

version ( unittest ) {}
else
void main ( )
{
    // Create temporary sandbox directory to write files to.
    auto sandbox = DirectorySandbox.create();
    scope (exit) sandbox.remove();

    // Helper function to write config, nodes, and credentials files and
    // instantiate a client to read them.
    void loadConfig ( cstring credentials )
    {
        auto cred_file = new File("credentials", File.ReadWriteCreate);
        cred_file.write(credentials);
        cred_file.close();

        auto nodes_file = new File("nodes", File.ReadWriteCreate);
        nodes_file.write("127.0.0.1:10000");
        nodes_file.close();

        auto config_file = new File("config.ini", File.ReadWriteCreate);
        config_file.write(
            "[NeoConfig]\nnodes_file = nodes\ncredentials_file = credentials");
        config_file.close();

        void connNotifier ( Client.Neo.ConnNotification ) { }

        auto parser = new ConfigParser("config.ini");
        auto config = Config.fill!(Client.Neo.Config)("NeoConfig", parser);

        auto client = new Client(new EpollSelectDispatcher, config,
            &connNotifier);
    }

    // Valid credentials file.
    loadConfig("test:0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000");

    // Credentials file with invalid key (too short).
    testThrown!(CredentialsParseException)(
        loadConfig("test:X0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")
    );

    // Credentials file with invalid key (too long).
    testThrown!(CredentialsParseException)(
        loadConfig("test:000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")
    );

    // Credentials file with mutliple lines.
    testThrown!(Exception)(
        loadConfig("test:0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000\ntest2:0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")
    );

    // Empty credentials file.
    testThrown!(Exception)(loadConfig(""));
}
