### Now possible to specify request timing via a flag in the request struct

`swarm.neo.node.ConnectionHandler`

The `addHandler` method of `RequestMap` currently accepts a bool which
determines whether timing stats are gathered for the request being added. All
other request properties are specified via fields in the request struct, rather
than by arguments passed to `addHandler`. It is now possible to also specify
the timing stats option in the same way, by including a field
`const bool timing = ?;` in the request struct. If this field is present, the
value of the argument passed to `addHandler` is ignored.

In the next major version, the timing argument to `addHandler` will be removed.

