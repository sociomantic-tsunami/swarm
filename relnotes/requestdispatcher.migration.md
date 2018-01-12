## Adapt `RequestEventDispatcher` usage to new `initialise` method: don't store in a pool

`swarm.neo.request.RequestEventDispatcher`

It's no longer recommended to keep the reusable RequestEventDispatcher instance,
instead it should reuse the internal arrays (obtained by the delegate passed
to the `initialise` method). All code using it must adapt to use the `initialise`
method in conjunction with `AcquiredResources.getVoidBuffer()` method.
