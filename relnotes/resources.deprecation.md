## Client request `Context.request_resources` renamed to `shared_resources`

`swarm.neo.client.mixins.RequestCore`

The request resources object should now be accessed via
`context.shared_resources`, instead of `context.request_resources.get()`.

