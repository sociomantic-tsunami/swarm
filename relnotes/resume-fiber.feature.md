* `swarm.neo.connection.RequestOnConnBase`

  The nested class `EventDispatcher` now has the ability to resume the outer
  class' (i.e. the request-on-conn instance) fiber. This can be useful for
  multi-fiber requests which are communicating with each other via fiber resume
  codes of the request-on-conn. In client request handlers, the actual
  request-on-conn instance is not available.

