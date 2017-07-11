/*******************************************************************************

    Test for library features version checking.

    Copyright:
        Copyright (c) 2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.LibFeatures_test;

import ocean.core.VersionCheck;

static assert(hasFeaturesFrom!("swarm", 4,0));
