## Support for multiple-nodes-at-a-time requests

`swarm.neo.client.RequestHandlers`, `swarm.neo.client.RequestSet`,
`swarm.neo.client.mixins.RequestCore`

A new type of request has been added: a request that initially operates on a
single `RequestOnConn`, but that has the facility to acquire further request-on-
conns, if required. In this way, it is possible to implement requests that are
in contact with multiple nodes simultaneously, where the exact nodes contacted
are determined at by the request handler itself. (This is in contrast to the
all-nodes request support, where the request handler is automatically called on
each connection, without any choice in the matter by the handler.)

