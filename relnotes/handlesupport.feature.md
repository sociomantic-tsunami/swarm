## `RequestCore.handleSupportedCodes` should be used to check for request support

`swarm.neo.request.Command`

Previously, the request supported/started handshake included request specific
steps, so the request would extend the `GlobalStatusCode` enum with the request
specific codes. This should no longer be used, but the request-specific errors
should be left to the request implementation to specify/handle (possibly at any
point during the request's lifetime). Swarm should be used just to check if the
request (and the request's version) are supported, and this is where
`handleSupportedCodes`, which checks if the node responded with the request
(not) supported code, should be used.
