## Register `ClientStats` with application's reopenable files extension

`swarm.util.log.ClientStats`

A new `ClientStats` constructor has been added that accepts the application
object. If this constructor is used, the `ClientStats` instance will be
automatically registered with the application's reopenable files extension, if
it exists.

