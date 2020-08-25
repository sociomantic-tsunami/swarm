### Added `swarm.neo.connection.RequestOnConnBase : RequestOnConnBase.Payload.addPointer`

`swarm.neo.connection.RequestOnConnBase`

This function was added as a possible future replacement of the less secure `add` function.
Since `add` takes its argument by ref, it would trigger a deprecation with recent compilers.
`add` has been fixed to forward to `addPointer` and will now longer issue deprecations.
