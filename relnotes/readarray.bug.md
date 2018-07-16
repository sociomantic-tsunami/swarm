### Validate the length of the array before reading it

* `swarm.protocol.FiberSelectReader`

`FiberSelectReader` will not reject to read arrays larger
than (by default) 10MB and it will throw `InputTooLargeException`.
