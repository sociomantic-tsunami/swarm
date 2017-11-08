## Name of connected client is now accessible via `Connection`

`swarm.neo.node.Connection`

The node `Connection` class has a new method -- `connected_client` -- that
returns the name of the connected client received during authentication. This
is useful for logging.

