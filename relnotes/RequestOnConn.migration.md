### `EventDispatcher.receive` passes received data as `const(void)[]`

The delegate parameter of the `EventDispatcher.receive()` method now takes
an array of const values, instead of a const array.
