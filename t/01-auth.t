use Mojo::Base -strict, -signatures;
use Test::More;
use lib 't/lib';
use TestSupport qw(fixture token client);
use Crypt::JWT qw(encode_jwt);
use Crypt::PK::RSA;
use MCP::Constants qw(PROTOCOL_VERSION);
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Util qw(b64_decode b64_encode);

my $f = fixture;
my $t = $f->{t};
my $reader = client($f);
my $writer = client($f, sub => 'bob', scope => 'mcp:read mcp:write mcp:admin');
my $admin = client($f, sub => 'carol', scope => 'mcp:read mcp:write mcp:admin', role => 'admin');

subtest '401 challenges and metadata' => sub {
  $t->post_ok('/mcp' => json => {})->status_is(401)
    ->header_like('WWW-Authenticate' => qr/^Bearer resource_metadata="http:\/\/127\.0\.0\.1:3000\/\.well-known\/oauth-protected-resource\/mcp"/);
  $t->post_ok('/mcp' => {Authorization => 'Bearer invalid'} => json => {})->status_is(401);
  for my $route ('/.well-known/oauth-protected-resource', '/.well-known/oauth-protected-resource/mcp') {
    $t->get_ok($route)->status_is(200)->json_is('/resource' => $f->{config}{audience})
      ->json_is('/scopes_supported' => [qw(mcp:admin mcp:read mcp:write)])
      ->json_is('/authorization_servers' => [$f->{config}{issuer}]);
  }
};
subtest 'JWT verification fails closed' => sub {
  my $auth = $t->app->demo_auth;
  ok $auth->validate_token(token($f)), 'valid RSA access token accepted';
  for my $case (
    [expired => {exp => time - 10}], [future => {nbf => time + 600}], [future_iat => {iat => time + 300}],
    [issuer => {iss => 'https://evil.test'}], [audience => {aud => 'different-service'}],
    [subject => {sub => ''}], [scope => {scope => ['mcp:admin']}], [role => {role => {admin => 1}}],
    [revoked => {jti => 'revoked-test-id'}], [expiration_type => {exp => 'not-a-time'}]
  ) {
    my $bad = token($f, %{$case->[1]});
    ok !$auth->validate_token($bad), "$case->[0] token rejected";
    $t->post_ok('/mcp' => {Authorization => "Bearer $bad"} => json => {})->status_is(401);
  }
  for my $missing (qw(exp iat iss aud sub)) {
    my $claims = {iss => $f->{config}{issuer}, aud => $f->{config}{audience}, sub => 'alice',
      exp => time + 600, iat => time, scope => 'mcp:read'};
    delete $claims->{$missing};
    my $bad = encode_jwt(payload => $claims, alg => 'RS256', key => $f->{key}, extra_headers => {typ => 'at+jwt'});
    ok !$auth->validate_token($bad), "missing $missing rejected";
  }
  my $claims = {iss => $f->{config}{issuer}, aud => $f->{config}{audience}, sub => 'alice',
    exp => time + 600, iat => time, scope => 'mcp:read'};
  ok !$auth->validate_token(encode_jwt(payload => $claims, alg => 'RS256', key => $f->{key}, extra_headers => {typ => 'JWT'})),
    'wrong JWT token type rejected';
  ok !$auth->validate_token(encode_jwt(payload => $claims, alg => 'HS256', key => $f->{config}{public_key}, extra_headers => {typ => 'at+jwt'})),
    'RSA public-key/HMAC algorithm confusion rejected';
  my $other = Crypt::PK::RSA->new->generate_key(256, 65537);
  ok !$auth->validate_token(encode_jwt(payload => $claims, alg => 'RS256', key => $other, extra_headers => {typ => 'at+jwt'})),
    'untrusted signing key rejected';
  my @parts = split /\./, token($f);
  my $payload = decode_json(b64_decode(($parts[1] =~ tr/-_/+\//r)));
  $payload->{role} = 'admin';
  $parts[1] = b64_encode(encode_json($payload), '') =~ tr/+\//-_/r;
  $parts[1] =~ s/=+$//;
  ok !$auth->validate_token(join '.', @parts), 'edited role invalidates signature';
  ok $auth->validate_token(token($f, aud => ['another-audience', $f->{config}{audience}])), 'audience array membership accepted';
};
subtest 'Identity, scopes and roles are independent' => sub {
  is $reader->call_tool('whoami')->{structuredContent}{principal}, 'alice', 'reader identity';
  is $writer->call_tool('whoami')->{structuredContent}{principal}, 'bob', 'writer identity';
  is $reader->call_tool('whoami')->{structuredContent}{principal}, 'alice', 'no identity leakage between requests';
  my %tools = map {$_->{name} => 1} @{$reader->list_tools->{tools}};
  ok !$tools{publish_preview}, 'reader cannot discover write primitive';
  eval { $reader->call_tool('publish_preview', {release => 'v1'}) };
  like $@, qr/-32003: Insufficient scope/, 'reader direct call rejected';
  eval { $writer->call_tool('admin_status') };
  like $@, qr/-32602/, 'admin scope without role cannot invoke hidden tool';
  like $admin->call_tool('admin_status')->{content}[0]{text}, qr/Administrator view/, 'admin with scope and role succeeds';
  my $no_scope = client($f, role => 'admin', scope => '');
  eval { $no_scope->call_tool('admin_status') };
  like $@, qr/-32003/, 'admin role without admin scope rejected';
  is_deeply [map {$_->{name}} @{$no_scope->list_tools->{tools}}], ['whoami'], 'missing scopes grant no scoped primitives';
  my %prompts = map {$_->{name} => 1} @{$writer->list_prompts->{prompts}};
  ok !$prompts{admin_review}, 'per-caller prompt filter';
  eval { $writer->get_prompt('admin_review') };
  like $@, qr/-32602/, 'hidden prompt cannot be invoked';
  my %resources = map {$_->{uri} => 1} @{$writer->list_resources->{resources}};
  ok !$resources{'demo:///admin'}, 'per-caller resource filter';
  eval { $writer->read_resource('demo:///admin') };
  like $@, qr/-32602/, 'hidden resource cannot be read';
  like $admin->get_prompt('admin_review')->{messages}[0]{content}{text}, qr/authentication/, 'admin prompt available';
  like $admin->read_resource('demo:///admin')->{contents}[0]{text}, qr/Administrator/, 'admin resource available';
};
subtest 'HTTP challenges, origin protection and routing headers' => sub {
  my $request = $reader->build_request('tools/call', {name => 'publish_preview', arguments => {release => 'v1'}});
  my $headers = {%{$reader->headers}, 'MCP-Protocol-Version' => PROTOCOL_VERSION,
    'Mcp-Method' => 'tools/call', 'Mcp-Name' => 'publish_preview'};
  $t->post_ok('/mcp' => $headers => json => $request)->status_is(403)
    ->header_like('WWW-Authenticate' => qr/error="insufficient_scope"/)
    ->header_like('WWW-Authenticate' => qr/scope="mcp:write"/);
  $headers->{Origin} = 'https://evil.test';
  $t->post_ok('/mcp' => $headers => json => $request)->status_is(403)->json_is('/error' => 'Origin not allowed');
  $headers->{Origin} = 'http://127.0.0.1:3000';
  $headers->{'Mcp-Name'} = 'whoami';
  $t->post_ok('/mcp' => $headers => json => $request)->status_is(400)->json_like('/error/message' => qr/does not match/);
  $t->get_ok('/mcp' => $reader->headers)->status_is(405);
  $t->delete_ok('/mcp' => $reader->headers)->status_is(405);
};
done_testing;
