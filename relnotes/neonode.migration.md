## `NeoNode`-derived classes must implement `getResourceAcquirer`

`swarm.node.model.NeoNode`

The method `getResourceAcquirer` is now abstract. All neo-capable node classes
must now implement this method, passing a scope-allocated request resource
acquirer to the provided delegate, for use in an active request handler.

