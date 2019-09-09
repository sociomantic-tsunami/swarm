### `EventDispatcher.receive` passes received data as `const(void)[]`

The delegate parameter of the `EventDispatcher.receive()` method now takes
an array of const values, instead of a const array.

### `EventDispatcher` now exposes `MessageParser` via an explicit alias

Various downstream code relies on being able to access `MessageParser` via
the `EventDispatcher` class, but this only works because the module import
is treated as implicitly public by the D compiler, and as of D 2.087 this
no longer works.  The new public alias should prevent this without needing
any changes from downstream code which expect the symbol to be visible.
