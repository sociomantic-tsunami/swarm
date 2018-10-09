### Add suspend unregister callback

* `swarm.client.RequestSetup`

Adds a delegate that may be used in any proto to give applications an option to
remove instances of type `ISuspendable` when a suspendable request finishes.
