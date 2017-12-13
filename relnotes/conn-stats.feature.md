## New connection stats iterators that also provide node addr/port

`swarm.neo.client.mixins.ClientCore`

`Stats.connection_io` and `Stats.connection_send_queue` both now have a second
`opApply` method that provides the address/port of the node, in addition to the
associated stats.

