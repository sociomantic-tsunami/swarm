## `GlobalStatusCode` enum is deprecated

`swarm.neo.request.Command`

Previously, the request supported/started handshake included request specific
steps, so the request would extend the `GlobalStatusCode` enum with the request
specific codes. This is going to be deprecated in favour of the request start
handshake only checking if the request/version is supported, leaving the
request specific codes out of swarm. As a result, the `GlobalStatusCode` enum
is deprecated and in the existing requests it should be renamed to
`SupportedStatus` which is backwards-compatible with it.
