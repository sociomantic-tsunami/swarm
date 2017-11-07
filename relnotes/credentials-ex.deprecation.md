## Replace `CredentialsParseException` with `KVFileParseException`

`swarm.neo.authentication.CredentialsFile`

Any code directly referring to `CredentialsParseException` should be adapted to
refer to `KVFileParseException` instead.

