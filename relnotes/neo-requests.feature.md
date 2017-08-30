* `swarm.neo.node.ConnectionHandler`

  The new `SharedParams` field `requests` augments the old map of command codes
  -> handler functions with additional information about supported requests.
  Currently, the only additional field stored about each request is a name -- a
  string which identifies the request. Further information may be added in the
  future.

* `swarm.node.model.NeoNode`

  The new `Options` field `requests` augments the old map of command codes
  -> handler functions as described for `swarm.neo.node.ConnectionHandler`,
  above.

