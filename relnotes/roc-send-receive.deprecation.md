* `swarm.neo.connection.RequestOnConnBase`

  The `EventDispatcher` methods `send` (varargs), `sendAndHandleEvents`,
  `receiveAndHandleEvents`, `yieldAndHandleEvents`,
  `yieldReceiveAndHandleEvents`, `periodicYieldAndHandleEvents`,
  `periodicYieldReceiveAndHandleEvents`, `sendReceive`,
  `sendReceiveAndHandleEvents` are now deprecated. Usage should be replaced with
  the combined `nextEvent` method.

