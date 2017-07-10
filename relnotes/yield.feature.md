* `swarm.neo.request.RequestEventDispatcher`

  Added method `yield` which causes a request fiber to suspend and then be
  resumed after an epoll event-loop cycle. Also `periodicYield` which has the
  same behaviour every n times it is called.

