# Validation record

Validated on October 29, 2026 with:

| Component | Version |
| --- | --- |
| Perl | 5.38.2 |
| MCP | 0.15 |
| Mojolicious | 9.53 |
| Crypt::JWT | 0.038 |
| CryptX | 0.091 |
| JSON::Schema::Tiny | 0.034 |

Command: `prove -lr t`

```text
t/01-auth.t ............... ok
t/02-primitives.t ......... ok
t/03-confirmation.t ....... ok
t/04-async-and-streams.t .. ok
t/05-stdio.t .............. ok
All tests successful.
Files=5, Tests=35
Result: PASS
```

The 35 top-level tests include nested subtests covering authentication,
authorization, schemas, results, resources, prompts, state integrity, concurrent
requests, cancellation, subscription cleanup and stdio. No external service is
contacted by this suite.

Also smoke-tested a real daemon with generated one-hour credentials and the
documented client commands: tour, progress, reader/writer/admin authorization,
confirmation without approval, explicitly approved confirmation, and announcing
while subscriptions are disabled. Token renewal preserves the signing key and
server state secret.

The optional streaming HTTP mode is exercised by `04-async-and-streams.t`,
including an independently authenticated administrator announcement.

The development issuer is deliberately not a live OAuth authorization server.
Live identity-provider login, key rotation, opaque-token introspection, external
MCP host compatibility and load-balanced production deployment were not tested.
See AUTHENTICATION.md for those integration boundaries.
