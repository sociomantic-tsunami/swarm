* `swarm.neo.client.mixins.RequestCore`, `swarm.neo.client.mixins.ClientCore`

  In order to enable fully const request assignment methods in the user-facing
  API, the handling of user-provided request parameters has been altered. Now,
  in order to be able to safely convert from the const parameters provided by
  the user to the mutable parameters stored in the request context, an
  intermediary serialization buffer is used. See `RequestCore.Context`. The
  external behaviour of the `ClientCore.assign` method is unchanged, except in
  the sense that the internal reworking allows it to also accept immutable
  parameters.

  To use this feature, request assignment like this:

  ```
    Internals.Put.UserSpecifiedParams params;
    params.args.key;
    params.args.value = value;
    params.notifier.set(notifier);

    this.assign!(Internals.Put)(params);
  ```

  Should be converted to:

  ```
    auto params = Const!(Internals.Put.UserSpecifiedParams)(
        Const!(Put.Args)(key, value),
        Const!(Internals.Put.UserSpecifiedParams.SerializedNotifier)(
            *(cast(Const!(ubyte[notifier.sizeof])*)&notifier)
        )
    );
  ```
