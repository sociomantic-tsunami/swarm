## Support for client per-Request-on-Conn working data removed

`swarm.neo.client.mixins.RequestCore`

This support was added in an early iteration of swarm neo but has turned out to
not be required by any request implementation.

Client-side request handler code must be adapted as follows:
* Remove the dummy `Working` struct from your request implementation.
* Do not pass the dummy `Working` struct as an argument to the `RequestCore`
  template mixin.
* Remove the `void[] working_blob` argument from your request's `handler`
  function.
* Remove the `IRequestWorkingData working_data_iter` from your request's
  `all_finished_notifier` function.

