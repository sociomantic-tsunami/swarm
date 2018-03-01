### `EventDispatcher.shutdownWithProtocolError` now throws instead of returning

`swarm.neo.connection.RequestOnConnBase`

The method `EventDispatcher.shutdownWithProtocolError` used to return an
exception with the expectation that the caller will throw it. The behaviour has
now changed such that `EventDispatcher.shutdownWithProtocolError` throws this
exception directly. This simplifies usage of the method.

