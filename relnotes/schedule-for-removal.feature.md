### Now possible to mark a request as scheduled for removal

`swarm.neo.node.ConnectionHandler`

The neo protocol includes versioning at the request level, making it easy to
cleanly make changes to request protocols without requiring synchronised updates
of clients and nodes. However, support for old request versions is only retained
as long as the node maintainer decides it is needed.

It is now possible to mark a request as "scheduled for removal" by adding a
static `bool scheduled_for_removal` field to your request struct.

Requests that are scheduled for removal are handled as normal, but the node:
1. Logs a warning.
2. Outputs `old_request_versions_in_use:1` to its stats log.

In this way, it is possible to tell when an older request version is no longer
in use, rather than having to guess.

