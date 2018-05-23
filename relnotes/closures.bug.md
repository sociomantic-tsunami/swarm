### Fixup of swarm internals to prevent closure allocation

Some of internal swarm code was refactored so that it doesn't allocate closures
when compiled with D2 anymore. New CI check was added to ensure this will also
hold true for all future swarm versions.
