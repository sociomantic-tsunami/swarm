## Old new node request handler framework deprecated

`swarm.neo.node.ConnectionHandler`

The old new request handler framework made request handler code overly
complicated, for the sake of avoiding copying the initial message payload from
the connection's read buffer into a request-owned buffer. This framework is now
deprecated and replaced with a new, simpler to implement framework. See new
features.

Existing code adding a request handler to the map that looks like this:
```D
options.requests.add(Command(RequestCode.Get, 0), "Get", GetImpl_v0.classinfo,
    timing);
```
should be changed to this:
```D
options.requests.addHandler!(GetImpl_v0)(timing);
```

Existing request handler implementations that look like this:
```D
class GetImpl_v0 : IRequestHandler
{
    void initialise ( RequestOnConn connection, Object resources ) { ... }
    void preSupportedCodeSent ( Const!(void)[] init_payload ) { ... }
    void postSupportedCodeSent ( ) { ... }
}
```
should be changed to this:
```D
class GetImpl_v0 : IRequest // Implement new interface
{
    // Add this.
    static const Command command = Command(RequestCode.Get, 0);

    // Add this.
    static istring name = "Get";

    void handle ( RequestOnConn connection, Object resources,
        Const!(void)[] init_payload )
    {
        // Combined code of the old initialise, preSupportedCodeSent, and
        // postSupportedCodeSent. Class fields used to store values parsed from
        // the initial payload can usually be moved to function locals.
    }
}
```

