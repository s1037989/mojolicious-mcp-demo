# Authentication, authorization and OAuth integration

## What this application actually implements

This is an MCP protected resource server. Its HTTP transport uses the `auth`
callback documented by CPAN MCP. The callback verifies a bearer access token and
returns the authenticated principal and granted scopes. A signed role is stashed
on that request's Mojolicious controller for the additional per-caller policy.

No token is accepted simply because it parses, is nonempty, or contains a role.
The verifier requires all of the following:

| Requirement | Enforcement |
| --- | --- |
| Authorization header | Bearer scheme, bounded length, compact signed JWT syntax; no query/cookie token fallback |
| Trusted signing key | Explicitly configured RSA public key, at least 2048 bits |
| Algorithm | RS256 only; `none`, HS256 and other algorithms rejected |
| Token type | JWT `typ` header must equal `at+jwt` |
| Issuer | Exact configured `iss` |
| Audience | Configured public `/mcp` URL, including when `aud` is an array |
| Expiration | Required `exp`; expired token rejected with no clock leeway |
| Issued-at | Required `iat`; future values rejected |
| Not-before | `nbf` honored when present |
| Subject | Required nonempty scalar `sub`, bounded length, no whitespace/control characters |
| Permissions | Space-separated `scope` string; missing scope grants no scoped access |
| Role | Application-specific signed `role`, either user or admin; absent defaults to user |
| Optional deny list | Configured `revoked_jti` entries rejected; restart workers after changes |

The verification key is a `Crypt::PK::RSA` public-key object, not a raw string
that could accidentally be interpreted as an HMAC secret. `Crypt::JWT` performs
signature and claim checks; the app pins the algorithm independently of the
untrusted token header. The server does not load a key URL supplied by `jku`,
`x5u`, embedded `jwk` or a caller-selected `kid`. The demo has one configured
trusted public key and deliberately does not implement automatic key discovery.

The local setup script signs short-lived development tokens with a generated
private key and a JWT type matching this access-token profile. The server itself
receives only the public key in its configuration. Keep the development signing
key off production resource-server hosts. A production authorization server
issues its own tokens and holds its own private keys.

## Request path

1. The HTTP transport checks browser `Origin` against an exact allowlist.
   Requests without an Origin header still need a valid access token.
2. `MCPDemo::Auth->authenticate($c)` extracts and validates the access token.
3. A false return produces HTTP 401 and the SDK's bearer challenge referencing
   the protected-resource metadata URI.
4. A successful return supplies `{principal => $sub, scopes => \@scopes}`.
5. Primitive-list events filter admin tools, prompts and resources by signed role.
   These same filtered collections govern direct invocation, so hiding is an
   authorization boundary rather than merely a menu preference.
6. The SDK checks each remaining primitive's required scopes. Every required
   scope must be granted. Direct insufficient-scope calls produce HTTP 403 and
   a bearer `insufficient_scope` challenge.
7. Input validation and the primitive's code then run. The context exposes
   principal, scopes, controller and negotiated client capabilities.

Do not remove the HTTP `auth` hook and expect `scopes => [...]` to protect an
endpoint. In MCP 0.15 scope restrictions depend on the transport's authenticated
scope set. Stdio intentionally has no such HTTP scope enforcement.

## OAuth discovery versus OAuth login

The app publishes both:

- `/.well-known/oauth-protected-resource/mcp`: the endpoint-specific metadata URI.
- `/.well-known/oauth-protected-resource`: the alias used in the module tutorial.

`oauth_metadata` derives supported scopes from the registered primitives. The
resource URL and authorization-server issuer come from trusted configuration,
not from the inbound Host header. A client gets this metadata URI in the 401
challenge, discovers the authorization server, obtains an access token, and
sends that token with subsequent requests.

The default issuer `https://demo-issuer.invalid` is an intentional placeholder.
There is no authorization endpoint, token endpoint, consent page, password
collection, refresh-token endpoint, dynamic client registration, or authorization
server metadata at that address. Local CLI-issued tokens let you test the resource
server independently of an identity provider. A generic host's automatic OAuth
login cannot complete against the default demo issuer. Use the supplied Perl
client or provide its token through a host-supported header mechanism.

For actual multi-user delegated authorization, configure a real OAuth authorization
server and a compatible MCP host. The host conducts its supported authorization
flow, normally Authorization Code with PKCE for a user-facing public client,
validates the callback state, and securely stores/refreshes credentials. Your
Mojolicious MCP app consumes the resulting access token. Neither the model nor
this resource server needs the user's password. An ID token is not an API access
token and should not be substituted for one.

MCP::Client deliberately does not perform OAuth login, refresh loops, input-request
retry loops or TTL caching for you; the supplied demo client implements only the
explicit confirmation retry needed for this demonstration.

## Adapting to your authorization server

Put `server.json` in a protected location and set `MCP_DEMO_CONFIG` to its absolute
path. Replace the development values with your public HTTPS origin, endpoint
audience, actual issuer and a trusted issuer verification key. Keep the state
secret shared across every worker. Set `streaming` to false for multi-worker use.

This sample enforces a specific RS256 / `at+jwt` access-token profile. Adapt it
deliberately if your issuer uses a different approved algorithm, token type,
claim layout, scope claim (`scp`, for example) or group/role representation.
Map those verified claims into the app's canonical principal/scopes/role rather
than weakening the validation to accept any token. This is especially important
when your issuer uses generic `JWT` token types for both ID and access tokens.

For rotating keys, maintain a trusted, issuer-specific key set or JWKS cache,
select a key by `kid` only within that trusted set, pin the permitted algorithms,
and bound cache lifetimes and refresh work. Never fetch a URL supplied by a token.
This package intentionally does not implement automatic JWKS refresh.

For opaque access tokens, replace `validate_token` with your issuer's validated
introspection result, requiring active status, correct resource/audience, expiry,
subject and scopes. Because the SDK's `auth` hook is synchronous, perform remote
introspection asynchronously in a preceding Mojolicious action and let the hook
consume the verified per-request result. Do not make blocking HTTP calls inside
the hook on the Mojolicious event loop. Fail closed on introspection errors and
bound any introspection cache by token expiration and revocation requirements.

## Confirmation state and downstream services

`input_required` state is authenticated, not encrypted. It travels through the
client and can be decoded, so do not put credentials or confidential documents
in it. The SDK binds the state to principal, tool and expiration. This app uses
only the sealed release identifier after confirmation and checks that the answer
is an actual JSON boolean true. Invalid or expired state starts a fresh question.

HMAC state does not enforce one-time use. The demonstration is a simulation and
does not mutate any external system. Before using this pattern for a real publish,
delete or deployment, add a shared durable operation record with a nonce and an
atomic pending-to-approved-to-executed transition (or equivalent idempotent
transaction). Re-check authorization and target state at execution time.

MCP authentication does not automatically authorize access to Jira or Confluence.
For those services, establish the appropriate delegated OAuth connection and
associate the downstream credential with the verified principal in server-side
storage. Check downstream permissions too, and do not forward this MCP audience's
bearer token to an unrelated service. There is no Atlassian integration in this
demonstration.

## Deployment limits

Use TLS outside loopback development, protect configuration, restrict network
reachability as appropriate, and ensure proxies do not log Authorization headers.
Do not expose detailed token validation exceptions to callers. This code responds
with the transport's generic unauthorized response.

JWT verification here is offline. A locally configured JTI deny list is a teaching
option loaded at startup, not a continuously synchronized revocation service.
Ordinary authorization changes take effect when a new token is issued and used,
the existing token expires, or the validator gains a revocation signal. Deploy a
revocation/introspection policy if your requirements call for immediate removal.

Optional subscription streams authenticate when opened and are held in one
process. The SDK does not automatically close them on token expiry or revocation,
and `notify_list_changed` broadcasts the generic signal to subscribed streams.
The demo broadcasts only a generic tool-list invalidation, with no caller-specific
data. Keep subscriptions disabled in production until you add an appropriate
maximum connection lifetime and revocation handling. Reauthentication occurs on
the next ordinary request; request progress/log streams do not require global
subscriptions. Long-running protected mutations should also re-check permissions
before committing their side effect.

The origin allowlist protects browser-origin requests, but it is not a substitute
for bearer authentication, TLS or a reverse proxy's Host policy. The demo does
not enable cross-origin browser CORS. A native MCP client normally has no Origin
header. Configure CORS deliberately if you add a browser client.

## Sources

- [MCP tutorial: authentication, scopes, per-caller primitives and deployment](https://metacpan.org/pod/MCP)
- [MCP HTTP transport auth and origin policy](https://metacpan.org/pod/MCP::Server::Transport::HTTP)
- [Context state sealing and replay limits](https://metacpan.org/pod/MCP::Server::Context)
- [Crypt::JWT algorithm pinning and claim verification](https://metacpan.org/pod/Crypt::JWT)
- [OAuth protected-resource metadata, RFC 9728](https://www.rfc-editor.org/rfc/rfc9728.html)
- [OAuth JWT access-token profile, RFC 9068](https://www.rfc-editor.org/rfc/rfc9068.html)
