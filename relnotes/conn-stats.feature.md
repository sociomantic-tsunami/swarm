* `swarm.neo.node.ConnectionHandler`

  New methods, `bytes_sent` and `bytes_received` are now available. These return
  the count of bytes sent or received over the connection since the last call to
  the method.

* `swarm.node.model.NeoNode`

  Data sent and received over neo connections is now included in the totals
  returned by `bytes_sent` and `bytes_received`.

