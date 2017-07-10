* `swarm.neo.connection.RequestOnConnBase`

  A new method -- `nextEvent` -- has been added to
  `RequestOnConnBase.EventDispatcher`. This is intended to (eventually) replace
  the myriad of methods providing handling of {reads/sends/yields/misc fiber
  resume codes} in (almost) all possible combinations (an approach which is
  clearly not maintainable).

