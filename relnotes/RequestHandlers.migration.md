### `UseNodeDg` delegate alias now returns `RequestOnConn.NodeState`

`swarm.neo.client.RequestHandlers`, `swarm.neo.client.RequestOnConn`

Previously, the `swarm.neo.client.RequestHandlers.UseNodeDg` delegate signature
had `bool` as its return type, which indicated success or failure of connection
to a node, without specifying the failure reason.

This delegate signature now has `RequestOnConn.NodeState` as its return type,
which is an enumerated state, indicating success, or failure, specifying if the
failure happened for the said node being absent or due to a connection failure.
