### Methods to convert between `AddrPort` and `NodeItem`

`swarm.neo.AddrPort`

Swarm uses two address/port representations internally (for historical reasons).
In the future, we will remove the old `NodeItem`, but for now it's useful to
have convenient methods for converting back and forth.

`AddrPort` now has the following new methods:
  * `typeof(this) set ( NodeItem node_item )`
  * `NodeItem asNodeItem ( ref mstring buf )`

