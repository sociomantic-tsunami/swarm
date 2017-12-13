## Strip down client core constructors to those used with config and in tests

`swarm.neo.client.mixins.ClientCore`

The following constructors are deprecated:
* The ctor that accepts the path of an authentication file, the connection
  notifier, and the shared resources instance.
* The ctor that accepts a parsed `Credentials` instance, the connection
  notifier, and the shared resources instance.
* The ctor that accepts the authentication name and key, the connection
  notifier, and the shared resources instance.
* The ctor that accepts a parsed `Config` instance, the connection notifier, and
  the shared resources instance.

Usage of the deprecated constructors should be replaced with calls to either:
* The ctor that accepts a parsed `Config` instance (specifying the paths of the
  authentication file and the nodes file) and a `Settings` instance (providing
  the connection notifier and the shared resources instance). (This is intended
  for use in real clients.)
* The ctor that accepts the authentication name and key and a `Settings`
  instance (providing the connection notifier and the shared resources
  instance). (This is intended for use in tests.)

