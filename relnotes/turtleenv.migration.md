## Turtle Node ext base class is now in swarm

`turtle.env.model.Node`

This module providing the common turtle ext node base class used to be included
in the protos. Because it's the same file, it's now moved into swarm. Proto
repositories should remove their copy of this file.

Couple of changes needs to be performed while updating the protos' implementations,
and client code:

- `ignoreErrors()` is now renamed to `log_errors(bool)` method which can
  enable/disable the error output.

- `node_item()` method has renamed to `node_addport` and now it returns
  `AddrPort` structure. Make sure you don't set the port/address directly,
  as the byte order might be different. Use setAddress()/port() setters/getters.
  For example:

      // Before:

      this.neo_address = NodeItem(this.node_item.address, this.node_item.port() + 100);

      // After:

      this.neo_address = AddrPort(this.node_item.address)

      // Important - port setter converts from host to network byte order
      this.neo_address.port() = cast(ushort)this.node_item.port() + 100;

- `createNode` (protected method) now accepts `AddrPort` structure instead
  `NodeItem` structure.
