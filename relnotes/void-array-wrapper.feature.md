* `swarm.neo.util.VoidBufferAsArrayOf`

  New helper template to wrap a `void[]`, allowing it to be safely accessed as
  if it's an array of another type.

* `swarm.neo.util.AcquiredResources`

  A new method `acquireWrapped` is added to `AcquiredArraysOf`. This method
  returns a safely wrapped `VoidBufferAsArrayOf!(T)`.

