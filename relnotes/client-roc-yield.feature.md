* `swarm.neo.client.ConnectionSet`

  The client `ConnectionSet` class now has a `YieldedRequestOnConns` field which
  is passed through to the individual `RequestOnConn` instances. This allows the
  yielding methods of `RequestOnConnBase.EventDispatcher` (i.e. `nextEvent`,
  `yieldAndHandleEvents`, `yieldReceiveAndHandleEvents`,
  `periodicYieldAndHandleEvents`, `periodicYieldReceiveAndHandleEvents`) to be
  used in client request handler code.

