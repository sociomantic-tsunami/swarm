/*******************************************************************************

    Meta module defining constants that match swarm feature releases allowing
    downstream libraries to conditionally implement functionality relying on
    later swarm versions.

    Copyright:
        Copyright (c) 2017 sociomantic labs GmbH. All rights reserved

    License:
        Boost Software License Version 1.0. See LICENSE.txt for details.

*******************************************************************************/

module swarm.LibFeatures;

static immutable has_features_4_5 = true;
static immutable has_features_4_4 = true;
static immutable has_features_4_3 = true;
static immutable has_features_4_2 = true;
static immutable has_features_4_1 = true;
static immutable has_features_4_0 = true;
static immutable has_features_3_3 = true;
static immutable has_features_3_2 = true;
static immutable has_features_3_1 = true;
static immutable has_features_3_0 = true;
