### New node request handler framework

`swarm.neo.node.ConnectionHandler`

The old new request handler framework made request handler code overly
complicated, for the sake of avoiding copying the initial message payload from
the connection's read buffer into a request-owned buffer. The new framework
automatically handles copying the initial message payload and passes a slice to
the copy to the `handle` method. See deprecation instructions for how to migrate
existing request handlers.

