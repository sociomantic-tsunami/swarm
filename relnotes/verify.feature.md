### Make ocean's `verify` always available

`swarm.util.Verify`

Implements `verify` as in ocean if the submodule ocean is earlier than v3.4, or
does a `public import ocean.core.Verify` otherwise. This is to allow for writing
new swarm code that can be safely merged into v5.
