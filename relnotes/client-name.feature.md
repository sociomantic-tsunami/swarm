## Name of connected client now accessible via `Connection` and `RequestOnConn`

`swarm.neo.node.Connection`, `swarm.neo.node.RequestOnConn`

The node `Connection` class has a new method -- `connected_client` -- that
returns the name of the connected client received during authentication. The
node `RequestOnConn` has the new `getClientName` method, returning the same.

The client name is useful for logging.

