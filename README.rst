Description
===========

Swarm is a framework for the creation of asynchronous, distributed
client/server systems. Swarm is built on top of ocean_.

.. _ocean: https://github.com/sociomantic-tsunami/ocean

A Tale of Two Protocols
-----------------------

The code in swarm is currently in transition. There exist two parallel client/
server architectures in the repo, a new architecture (dubbed "neo") -- located
in the ``src/swarm/neo`` package -- and a legacy architecture -- located in the
other packages of ``src/swarm``. The neo protocol is being introduced in stages,
progressively adding features to the core client and server code over a series
of releases.

When sufficient neo features have been implemented and the legacy protocol is no
longer in active use, the legacy protocol will be deprecated and eventually
removed.

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

Client Documentation
--------------------

An overview of the features of the legacy and neo client architecture can be
found here

`Legacy client documentation
<https://github.com/sociomantic-tsunami/swarm/blob/v4.x.x/src/swarm/README_client.rst>`_.

`Neo client documentation
<https://github.com/sociomantic-tsunami/swarm/blob/v4.x.x/src/swarm/README_client_neo.rst>`_.

Example
-------

A simple example of how to construct a client and node using the neo protocol
can be found `here
<https://github.com/sociomantic-tsunami/swarm/blob/v4.x.x/test/neo/>`_.

Build / Use
===========

Dependencies
------------

========== =======
Dependency Version
========== =======
ocean      v3.1.x
makd       v1.5.x
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

If you plan to use the provided ``Makefile`` (you need it to convert code to
D2, or to run the tests), you need to also checkout the submodules with ``git
submodule update --init``. This will fetch the `Makd
<https://github.com/sociomantic-tsunami/makd>`_ project in ``submodules/makd``.


Conversion to D2
----------------

Once you have all the dependencies installed, you need to convert the code to
D2 (if you want to use it in D2). For this you also need to build/install the
`d1to2fix <https://github.com/sociomantic-tsunami/d1to2fix>`_ tool.

Also, make sure you have the Makd submodule properly updated (see the previous
section for instructions), then just type::

  make d2conv

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
* Maintained minor versions: 1 most recent


Maintained Major Branches
-------------------------

====== ==================== ===============
Major  Initial release date Supported until
====== ==================== ===============
v3.x.x v3.2.0_: 17/01/2017  05/10/2017
v4.x.x v4.0.0_: 05/04/2017  TBD
====== ==================== ===============

.. _v3.2.0: https://github.com/sociomantic-tsunami/swarm/releases/tag/v3.2.0
.. _v4.0.0: https://github.com/sociomantic-tsunami/swarm/releases/tag/v4.0.0

