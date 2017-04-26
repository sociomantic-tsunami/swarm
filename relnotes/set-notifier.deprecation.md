* `swarm.neo.client.mixins.RequestCore`

  The method `UserSpecifiedParams.notifier.set` is deprecated. Code which sets
  up request parameters for passing to `ClientCore.assign` should be modified to
  set up a const instance of `UserSpecifiedParams`. See release note on adapting
  to a fully const request API.

