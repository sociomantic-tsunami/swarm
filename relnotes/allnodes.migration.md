## Client all-nodes / suspendable cores automatically handle supported codes

`swarm.neo.client.mixins.AllNodesRequestCore`,
`swarm.neo.client.mixins.SuspendableRequestCore`

The `HandleStatusCode` template arguments and the corresponding runtime
arguments (where apporpriate) have been removed from:
    * `AllNodesRequestInitialiser`
    * `createAllNodesRequestInitialiser`
    * `SuspendableRequestInitialiser`
    * `createSuspendableRequestInitialiser`

`AllNodesRequestInitialiser` now handles un/supported codes automatically,
calling the request struct's `handleSupportedCodes` function.
    
User code that specifies a status code handler should be adapted as follows:
    1. Any handling of un/supported codes should be removed.
    2. Handling of request-specific status codes should be moved into the main
       request handler function (i.e. the `Handler` policy of
       `AllNodesRequestCore`).

