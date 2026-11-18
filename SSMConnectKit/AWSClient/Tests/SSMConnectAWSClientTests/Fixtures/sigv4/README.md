# Signature Version 4 test suite

The `v4` cases of the AWS signing test suite, copied unchanged from
[awslabs/aws-c-auth](https://github.com/awslabs/aws-c-auth/tree/cf69fb7edf7c973524348bbcecda1b1684de4d5e/tests/aws-signing-test-suite/v4)
at commit `cf69fb7edf7c973524348bbcecda1b1684de4d5e`, under the Apache License 2.0
in `LICENSE`. `SigV4Tests` signs each `request.txt` with its `context.json` and
compares the canonical request, string to sign and signature for header and
query signing.
