* `swarm.node.model.NeoNode`

  The base neo node now supports the following additional unix socket commands:
    * `reset`: Responds with `ACK` and does nothing. (This command is required
      for compatibility with turtle's support for sending commands to the tested
      application via a unix socket. A specific implementation of this command
      is currrently not needed in the swarm node, so it does nothing.)

