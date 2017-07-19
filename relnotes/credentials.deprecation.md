* `swarm.neo.authentication.Credentials`

  * The `LengthLimit` constants and the `validateNameCharacters` are now at
    module-level, not nested in a struct.

  * The client-side `Credentials` struct has been moved to
    `swarm.neo.authentication.ClientCredentials`.

* `swarm.neo.authentication.CredentialsFile`

  * The file parsing code which existed in the `CredentialsFile` class has been
    moved to modlue-level.

  * The node-side `CredentialsFile` class has been moved to
    `swarm.neo.authentication.NodeCredentials` and is now named `Credentials`.

  * The `ParseException` class which existed in the `CredentialsFile` class has
    been moved to modlue-level and renamed to `CredentialsParseException`.

