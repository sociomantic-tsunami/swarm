## It is now safe to pass stack-based array slices to Payload.addArray()

`swarm.neo.connection.RequestOnConnBase`

`addArray` adds two things to the list of `void[][]` that will be sent: 1. a
slice of the array's length; 2. a slice of the array's content.

Previously, the actual length property of the array passed to `addArray` was
sliced directly and added to the payload. This made usage of `addArray` tricky,
as arrays stored on the stack, while they would be accepted by the method, would
lead to data corruption, as the sliced length would refer to stack memory.

Now, `addArray` does not directly slice the length property of the passed array.
Instead, the length is copied into an internal buffer and a slice to that buffer
is added to the payload. This makes `addArray` less treacherous to use.

