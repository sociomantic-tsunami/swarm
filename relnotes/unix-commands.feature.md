* `swarm.node.model.NeoNode`

  The base neo node now supports the following additional unix socket commands:
    * `reset`: Responds with `ACK` and does nothing. (This command is required
      for compatibility with turtle's support for sending commands to the tested
      application via a unix socket. A specific implementation of this command
      is currrently not needed in the swarm node, so it does nothing.)
    * `drop-all-connections`: Finalises all open connections (both legacy and
      neo). The select listeners remain active, so new connections can still be
      accepted. This is useful in test suites, where the behaviour of a client
      in the case of connection loss must be tested.

