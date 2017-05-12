* `swarm.node.storage.listeners.Listeners`

  The `Code` enum in `IListener` has a new member -- `Deletion` -- which may be
  triggered by the storage engine when a record is removed.

  (Note that, as the storage engine implementation is solely responsible for
  triggering the listener codes, the addition of this enum member is not a
  breaking change.)
