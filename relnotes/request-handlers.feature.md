## Node's map of request handlers now works per request _version_

`swarm.neo.node.ConnectionHandler`, `swarm.neo.node.IRequestHandler`

A new overload of `ConnectionHandler.RequestMap.add` allows request information
(including a `ClassInfo` denoting a request handler class to use) to be mapped
by a `Command` struct instance (see `swarm.neo.request.Command`). The important
point here is that a `Command` struct instance describes a specific _version_ of
a request. Thus, different request information (in particular, handler classes)
can be provided for each version of a request.

For requests registered with this new method, the node will automatically send
an un/supported code to the client.

Requests that wish to use this new system must implement the new
`IRequestHandler` interface.

