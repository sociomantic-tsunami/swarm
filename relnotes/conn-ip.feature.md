* `swarm.protocol.FiberSelectWriter`, `swarm.protocol.FiberSelectReader`

  The fiber select reader and writer now have a new field, `addr_port`, of type
  `IAddrPort` (see `swarm.protocol.IAddrPort`). This is an interface which, if
  non-null, allows the address and port of the underling socket to be got. In
  the node connection handler, these fields will be non-null, allowing a request
  handler to get the address and port of the connection socket.

