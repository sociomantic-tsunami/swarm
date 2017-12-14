## Automatic connection establishment may be disabled and triggered manually

`swarm.neo.client.mixins.ClientCore`

Previously, as soon as a node address is registered with the client (via
`addNode`), connection initialisation began. This remains the default behaviour,
but it is now possible to disable this by passing a `Settings` instance to the
client constructor, with the field `auto_connect` set to false.

Applications that construct a client in this way will then need to _manually_
call the `connect()` method of the client at a convenient juncture.

