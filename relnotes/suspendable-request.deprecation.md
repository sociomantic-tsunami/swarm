* `swarm.neo.node.helper.SuspendableRequest`,
  `swarm.neo.client.helper.SuspendableRequest`

  The old, side suspendable request helpers are now out-moded. Requests based
  on these structs should be reimplemented to work with multiple fibers and use
  the `RequestEventDispatcher`. See `test.neo.client.request.internal.GetAll`
  and `test.neo.node.request.GetAll` for example.

