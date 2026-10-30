# Mojolicious MCP demonstration

A runnable Perl application built with CPAN's **MCP 0.15**, following the
[MCP tutorial](https://metacpan.org/pod/release/SRI/MCP-0.15/lib/MCP.pm).
It demonstrates every tutorial topic, with particular attention to authentication.
The examples use Mojolicious signatures and work on Perl 5.20 or newer.

The application implements a protected MCP **resource server**. It validates
signed access tokens on every HTTP request. The included CLI generates local
demonstration tokens; it is not an OAuth authorization server or a browser login.
See [Authentication](docs/AUTHENTICATION.md) for the boundary and production integration.

## Quick start

From this directory, with `cpanm` installed:

```sh
cpanm --installdeps .
perl script/demo-setup
perl script/mcp-demo daemon -l http://127.0.0.1:3000
```

Or install into a local directory:

```sh
cpanm -L local --installdeps .
perl -Ilocal/lib/perl5 script/demo-setup
perl -Ilocal/lib/perl5 script/mcp-demo daemon -l http://127.0.0.1:3000
```

Use `perl -Ilocal/lib/perl5` for the client commands below too if you chose the
local installation. The dependency list is in `cpanfile`: MCP 0.15,
Mojolicious >= 9.41, Crypt::JWT >= 0.038, and CryptX >= 0.087. MCP also brings
IPC::Run and JSON::Schema::Tiny. CryptX contains XS code and requires a compiler
when installed from source; JSON::Schema::Tiny has additional transitive dependencies.
No LLM account, API key, database or external service is needed to run this demo.

For an air-gapped installation, prepare all runtime/build dependencies and their
transitive dependencies on a matching connected Perl/OS environment, then install
from your local CPAN mirror. This ZIP is application source, not an offline CPAN bundle.

In a second terminal:

```sh
perl script/demo-client tour
perl script/demo-client progress
perl script/demo-client --profile reader auth
perl script/demo-client --profile writer auth
perl script/demo-client --profile admin auth
perl script/demo-client --profile writer confirm
perl script/demo-client --profile writer --approve confirm
```

`demo-client` uses `MCP::Client`. Its default `tour` command lists tools, prompts
and resources and exercises text, errors, image, audio, links, structured data,
both prompt roles, and both text and binary resources. `progress` requests
progress and info-level client log notifications. `confirm` performs no actual
publish; `--approve` explicitly approves the simulation.

Tokens expire after one hour. Renew them without changing the server's keys:

```sh
perl script/demo-setup --renew
```

The setup script will not overwrite an existing configuration. It writes
`var/server.json`, `var/demo-private.pem` and three token files using restrictive
creation permissions. Keep `var` private and out of source control. No keys or
working bearer tokens are included in this source package.

## Authentication demonstration

| Profile | Subject | Signed scopes | Signed role | Effective access |
| --- | --- | --- | --- | --- |
| reader | alice | mcp:read | user | Read tools, prompts and resources |
| writer | bob | mcp:read mcp:write mcp:admin | user | Read plus publish simulation; admin primitives remain unavailable |
| admin | carol | mcp:read mcp:write mcp:admin | admin | All demonstration primitives |

The writer intentionally has an administrator scope without the administrator
role, so you can see the per-caller policy add a restriction beyond scopes.
Ordinarily, do not issue unused privileged scopes to users.

1. A missing, expired, forged or invalid access token receives HTTP `401` and a
   `WWW-Authenticate: Bearer resource_metadata="..."` challenge.
2. `/.well-known/oauth-protected-resource/mcp` identifies the protected resource,
   issuer and scopes. The root metadata URI from the POD is also served.
3. A valid bearer token becomes `{principal, scopes}` in the HTTP `auth` hook.
   The signed role is placed in the request controller's stash.
4. The SDK enforces required scopes on both discovery and direct invocation.
   A direct call with insufficient scope receives HTTP `403` and an
   `insufficient_scope` challenge.
5. The `tools`, `prompts` and `resources` events additionally remove administrator
   primitives for a caller without the admin role. Removed primitives cannot be
   invoked by guessing their name or URI.
6. `whoami` returns the current request's identity. No identity or role is read
   from a tool argument, query parameter, cookie or client-supplied role header.

Each HTTP request authenticates independently; a browser session is not required.
This server does not pass its bearer token through to Jira, Confluence or another
service. Such a service needs its own delegated authorization and audience.

The authentication hook is intentionally easy to locate in `lib/MCPDemo.pm`:

```perl
$self->routes->any('/mcp')->to(cb => $server->to_action({
  auth         => sub ($c) { $auth->authenticate($c) },
  metadata_url => "$config->{base_url}/.well-known/oauth-protected-resource/mcp",
  origins      => $config->{allowed_origins},
  streaming    => $config->{streaming} ? 1 : 0
}));
```

The actual JWT validation is in `lib/MCPDemo/Auth.pm`; this is not an
"accept any nonempty token" example.

## Tutorial coverage map

| MCP POD topic | Concrete demonstration | Verification |
| --- | --- | --- |
| Concepts | Tools, prompts and resources registered in `MCPDemo::Server` | `demo-client tour` |
| Your first server | `echo` returns a plain string as a text result | `02-primitives.t` |
| Talking to your server | JSON-RPC metadata and newline-delimited stdio | `05-stdio.t`, example below |
| Connecting a client | `script/demo-client` uses `MCP::Client`; host configurations below | Client tour and stdio test |
| Web applications | `MCPDemo` mounts `to_action` on `/mcp` | HTTP tests |
| Testing | `Test::Mojo` and a real `MCP::Client` sharing its user agent | All HTTP tests |
| Validating arguments | String length, number type, integer bounds, release-name pattern, required fields, no extra properties | `02-primitives.t` |
| Tool results | Plain/explicit text, recoverable error, image, audio, resource link; sanitized exceptions | `result_demo`, `divide`, `exception_demo` |
| Structured results | `perl_version` output schema and deliberate `broken_contract` failure | `02-primitives.t` |
| Prompts | Required module argument; default user role; explicit assistant role | `explain_module`, `mentor` |
| Resources | Registered text URI, PNG binary resource, caller-specific text | `handbook`, `pixel`, `current_caller` |
| Non-blocking tools | `count_steps` returns a `Mojo::Promise` while timer work runs | Concurrent HTTP request test |
| Progress reports | `notify_progress`, opt-in progress token, request SSE stream | `demo-client progress` |
| Logging | Per-request `notify_log`, severity filtering, server `Mojo::Log` on STDERR | `04-async-and-streams.t` |
| Cancellation | Context `cancelled` event removes timer; `is_cancelled` polling guard | HTTP disconnect test |
| Asking the client for input | `input_required`, form capability check, accept/decline/cancel, sealed state | `03-confirmation.t` |
| Authentication and scopes | JWT verification, auth hook, metadata, challenges and enforced scopes | `01-auth.t` |
| Per-caller primitives | Filter all three primitive kinds; role and scope checks are independent | `01-auth.t` |
| Caching | `cache_ttl` in milliseconds, private lists/scoped resources, zero TTL on caller data | `02-primitives.t` |
| Notification streams | Optional `subscriptions/listen` plus `notify_list_changed` | Streaming test and commands below |
| Deployment | Shared state secret, pre-forking with streaming off, single-process stream mode | Deployment instructions below |

`exception_demo` and `broken_contract` are intentionally broken teaching tools,
visible only to the administrator. Remove them from a production service.

## Prompts, resources and results

Tools are functions a model can choose to call. Prompts are templates the user
chooses. Resources are documents a client can read and attach as context.
Resource URIs such as `demo:///handbook` are identifiers; the application does
not open a client-selected filesystem path.

Returning a string makes a text result. For predictable operational failures,
return `$tool->text_result($message, 1)` so the model can react. Unexpected Perl
exceptions become generic protocol errors; the server log receives the detail.
`structured_result` checks output against `output_schema` and also returns JSON
as text for clients that need it. Image/audio constructors accept binary bytes;
the SDK base64-encodes them. Binary resources use a `blob` field.

For asynchronous tools, capture `$tool->context` before the asynchronous boundary.
`count_steps` sends progress and logs on that request's SSE response and resolves
its promise to the final tool result. It catches rejections, stops its timer on
cancellation, and releases the promise when the client disconnects.

`publish_preview` asks for form input only if the client declares
`elicitation => {form => {}}`. The SDK seals state using HMAC-SHA256, expiry,
principal and tool binding. The retry reads the approved release from verified
state, never from the retry arguments. Only JSON boolean `true` approves;
decline, cancel and false all stop the simulation. This example is replayable
within the state lifetime because it makes no changes. A real one-time operation
needs an atomic nonce/idempotency record; HMAC state alone does not prevent replay.

Cache hints do not create a server cache. Clients or gateways decide how to use
them. Scoped resources and caller-dependent lists are private; caches must also
respect authentication expiry and revocation. `demo:///me` has zero TTL.

## Stdio and host configuration

```sh
perl script/stdio-server
```

Paste a request on one line:

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"echo","arguments":{"message":"hello"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
```

For a host that launches local MCP processes, adapt this configuration:

```json
{
  "mcpServers": {
    "perl-demo": {
      "command": "perl",
      "args": ["/absolute/path/mojolicious-mcp-demo/script/stdio-server"]
    }
  }
}
```

For an HTTP-capable host, the essential connection data is:

```json
{
  "mcpServers": {
    "perl-demo": {
      "url": "http://127.0.0.1:3000/mcp",
      "headers": {"Authorization": "Bearer REPLACE_WITH_AN_ACCESS_TOKEN"}
    }
  }
}
```

Configuration filenames, header support, secure credential storage and OAuth
support vary by host. Prefer the host's credential mechanism over copying tokens
into a shared configuration file. The supplied Perl client reads a private token
file and is the tested reference client for this package.

Stdio trusts the operating-system user who starts the process. The SDK's HTTP
bearer hook is not run and scopes are not enforced over stdio. Our role filters
keep admin primitives hidden there, but `publish_preview` remains visible to
the local process owner. Never expose a raw stdio server as a multi-user network
service. Application logging belongs on STDERR; STDOUT carries JSON-RPC only.

## Optional notification streams

For a fresh separate configuration with streaming enabled:

```sh
perl script/demo-setup --dir var-stream --streaming
MCP_DEMO_CONFIG="$PWD/var-stream/server.json" perl script/mcp-demo daemon -l http://127.0.0.1:3000
```

Stop the default server first because these examples use the same port. Then:

```sh
perl script/demo-client --token-file var-stream/reader.token listen
```

In another terminal:

```sh
perl script/demo-client --profile admin --token-file var-stream/admin.token announce
```

The subscriber receives an acknowledgement and a tools-list invalidation signal.
This teaching action does not change the actual registered tools. Global
subscriptions use per-process state: use one daemon process, not `prefork`,
Hypnotoad or multiple load-balanced instances in this mode. Progress and log
notifications work with normal request streams even when subscriptions are off.
A subscription is authenticated when opened; this SDK does not revalidate it
when the token expires. See the deployment limits in the authentication guide.

## Testing and deployment

```sh
prove -lr t
```

For a local dependency installation:

```sh
PERL5LIB="$PWD/local/lib/perl5" prove -lr t
```

Tests generate ephemeral RSA keys. They cover valid and invalid authentication,
scope and role authorization, metadata/challenges, input/output schemas, all
result constructors, prompt/resource access, sealed-state security, async
progress/logging/concurrency, disconnect cancellation, subscriptions, and stdio.
They require no external network. `Test::Mojo` serves requests on a local
ephemeral listener managed by its user agent.

With `streaming` false (the default), deploy like another Mojolicious app:

```sh
MCP_DEMO_CONFIG=/secure/location/server.json perl script/mcp-demo prefork -l http://127.0.0.1:3000
```

All workers and instances must share the same `state_secret`, token verification
key, issuer, audience and policy. The setup script generates a 256-bit random
state secret; never generate it independently in each worker. For HTTPS behind a
reverse proxy, set `base_url` and `audience` to the public HTTPS origin and `/mcp`
endpoint, use an actual authorization server issuer, and configure allowed origins.
Configure forwarding headers only for your trusted proxy. Avoid proxy buffering
on SSE responses, and set a request/stream timeout appropriate to bounded work.

The SDK's current protocol is `2026-07-28`, with per-request metadata and routing
headers. This package pins the SDK version rather than mixing older initialize /
session examples into it. MCP 0.15 contains some legacy protocol support, but
this package's tests target the current version; verify your chosen host's
compatibility. `MCP::Client` builds the required headers and metadata for you.

## Layout and references

- `lib/MCPDemo.pm`: Mojolicious routes, auth hook, OAuth metadata, origin policy.
- `lib/MCPDemo/Auth.pm`: pinned-key JWT access-token verification.
- `lib/MCPDemo/Server.pm`: reusable primitive registration and request behavior.
- `lib/MCPDemo/Config.pm`: configuration loading and validation.
- `script/demo-setup`: generate development keys and short-lived credentials.
- `script/demo-client`: runnable client demonstrations.
- `script/stdio-server`: reuse the primitives over stdio.
- `t/`: protocol and security tests.
- `docs/AUTHENTICATION.md`: token trust, OAuth boundary, production adaptation.

Primary references consulted:

- [MCP 0.15 tutorial](https://metacpan.org/pod/release/SRI/MCP-0.15/lib/MCP.pm)
- [MCP::Server](https://metacpan.org/pod/MCP::Server)
- [MCP::Server::Transport::HTTP](https://metacpan.org/pod/MCP::Server::Transport::HTTP)
- [MCP::Server::Context](https://metacpan.org/pod/MCP::Server::Context)
- [MCP::Client](https://metacpan.org/pod/MCP::Client)
- [Crypt::JWT](https://metacpan.org/pod/Crypt::JWT)
