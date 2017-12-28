## Node's map of request handlers now works per request _version_

`swarm.neo.node.ConnectionHandler`

A new overload of `ConnectionHandler.RequestMap.add` allows request information
(including a handler function) to be mapped by a `Command` struct instance (see
`swarm.neo.request.Command`). The important point here is that a `Command`
struct instance describes a specific _version_ of a request. Thus, different
request information (in particular, handler functions) can be provided for each
version of a request.

