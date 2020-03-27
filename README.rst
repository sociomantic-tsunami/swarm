Description
===========

Swarm is a framework for the creation of asynchronous, distributed
client/server systems. Swarm is built on top of ocean_.

.. _ocean: https://github.com/sociomantic-tsunami/ocean

A Tale of Two Protocols
-----------------------

The code in swarm is currently in transition. There exist two parallel client/
server architectures in the repo: a new architecture (dubbed "neo") -- located
in the ``src/swarm/neo`` package -- and a legacy architecture -- located in the
other packages of ``src/swarm``. The neo protocol is being introduced in stages,
progressively adding features to the core client and server code over a series
of releases.

When the legacy protocol is no longer in active use, it will be deprecated and
eventually removed.

User Documentation
==================

An overview of the features of the legacy and neo client architecture can be
found here:

`Legacy client documentation <src/swarm/README_client.rst>`_.

`Neo client documentation <src/swarm/README_client_neo.rst>`_.

Neo Support in Clients
----------------------

The neo client functionality is implemented in such a way that it can be added to
existing legacy clients. Thus, the functionality of _both_ protocols can be
accessed through a single client instance. (Likewise, the servers are able to
handle requests of both types, handling the two protocols on different ports.)

While the neo architecture is being developed, the legacy protocol and the
associated client features remain unchanged -- indeed, there is no interaction
between the neo functionality and the legacy functionality of the client, except
at the system level (e.g. the allocation of file descriptors, etc).

Developer Documentation
=======================

Architectural overviews of the neo client/protocol/server:

`Neo protocol overview <src/swarm/README_protocol_neo.md>`_.

Example
-------

A simple example of how to construct a client and node using the neo protocol
can be found `here <integrationtest/neo/>`_.

Build / Use
===========

Dependencies
------------

========== =======
Dependency Version
========== =======
ocean      v4.0.x
makd       v2.1.x
turtle     v9.0.1
========== =======

The following libraries are required (for an absolutely up to date list you can
take a look at the ``Build.mak`` file, in the ``$O/%unittests`` target):

* ``-lglib-2.0``
* ``-lebtree``
* ``-llzo2``
* ``-lgcrypt``
* ``-lgpg-error``
* ``-lrt``

Please note that ``ebtree`` is not the vanilla upstream version. We created our
own fork of it to be able to write D bindings more easily. You can find the
needed ebtree library in https://github.com/sociomantic-tsunami/ebtree/releases
(look only for the ``v6.0.socioX`` releases, some pre-built Ubuntu packages are
provided).

If you plan to use the provided ``Makefile`` (you need it to run the tests),
you need to also checkout the submodules with ``git submodule update --init``.
This will fetch the `Makd<https://github.com/sociomantic-tsunami/makd>`_ project
in ``submodules/makd``.

Versioning
==========

swarm's versioning follows `Neptune
<https://github.com/sociomantic-tsunami/neptune/blob/master/doc/library-user.rst>`_.

This means that the major version is increased for breaking changes, the minor
version is increased for feature releases, and the patch version is increased
for bug fixes that don't cause breaking changes.

Support Guarantees
------------------

* Major branch development period: 6 months
* Maintained minor versions: 2 most recent

Maintained Major Branches
-------------------------

====== ==================== ===============
Major  Initial release date Supported until
====== ==================== ===============
v6.x.x v6.0.0_: 04/06/2019  TBD
====== ==================== ===============

.. _v6.0.0: https://github.com/sociomantic-tsunami/swarm/releases/tag/v6.0.0

Contributing
============

See the guide for `contributing to Neptune-versioned libraries
<https://github.com/sociomantic-tsunami/neptune/blob/master/doc/library-contributor.rst>`_.
