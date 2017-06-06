* `swarm.neo.util.AcquiredResources`

  A new helper, `AcquiredSingleton` has been added. This provides the behaviour
  required in cases where a single resource from the shared pools per request
  can be acquired. Once a request has acquired the resource, the same instance
  can be accessed by calling the `acquire` method again. See usage example.
