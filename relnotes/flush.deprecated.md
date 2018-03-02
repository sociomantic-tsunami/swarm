### TCP_CORK based flush is deprecated

`swarm.neo.connection.ConnectionBase`, `swarm.neo.connection.RequestOnConnBase`,
`swarm.neo.protocol.socket.MessageSender`

The existing `flush` method relied on the TCP_CORK being set and it would then
pull out and put the cork back in.  However this doesn't work, because putting
the cork back in had to be done after all the packets are actually sent,
otherwise the last incomplete packet will be delayed for the 200ms. Since we
moved to the explicit application buffering for the large data and to the
explicit flushing for the control messages this flush was deprecated.

Since now the TCP_NODELAY is always on, `ClientCore.enableNoDelay` and
`NeoNode.Options.no_delay` are now also deprecated and do nothing.

All the implicit batching in the requests should be mitigated to the explicit
batching (like preparing batches and sending them) and the explicit flushing after
sending small quick control messages should be removed, as TCP_NODELAY will send
the message as soon as it's written.
