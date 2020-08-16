/*******************************************************************************

    Helper module to use `verify` from ocean v3.4 instead of `assert`, even if
    the ocean submodule is at a version that does not include
    `ocean.core.Verify`. This is to allow for writing new swarm code that can be
    safely merged into v5.

    Copyright: Copyright (c) 2018 dunnhumby Germany GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE_BOOST.txt for details.
        Alternatively, this file may be distributed under the terms of the Tango
        3-Clause BSD License (see LICENSE_BSD.txt for details).

*******************************************************************************/

deprecated("Import `ocean.core.Verify` directly instead")
module swarm.util.Verify;

import ocean.core.VersionCheck;

public import ocean.core.Verify;
