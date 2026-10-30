package TestSupport;
use Mojo::Base -strict, -signatures;
use Crypt::JWT qw(encode_jwt);
use Crypt::PK::RSA;
use Crypt::PRNG qw(random_bytes);
use Exporter 'import';
use File::Temp qw(tempdir);
use Mojo::File qw(path);
use Mojo::JSON qw(encode_json false true);
use MCP::Client;
use Test::Mojo;
our @EXPORT_OK = qw(fixture token client);

sub fixture (%options) {
  my $dir = tempdir(CLEANUP => 1);
  my $key = Crypt::PK::RSA->new->generate_key(256, 65537);
  my $config = {
    public_key => $key->export_key_pem('public'), issuer => 'https://issuer.example.test',
    audience => 'http://127.0.0.1:3000/mcp', base_url => 'http://127.0.0.1:3000',
    state_secret => unpack('H*', random_bytes(32)), streaming => $options{streaming} ? true : false,
    revoked_jti => ['revoked-test-id']
  };
  my $file = path($dir, 'server.json')->spurt(encode_json($config));
  $ENV{MCP_DEMO_CONFIG} = "$file";
  my $t = Test::Mojo->new('MCPDemo');
  $t->app->log->level('fatal');
  return {dir => $dir, key => $key, config => $config, t => $t};
}
sub token ($f, %claims) {
  my $payload = {iss => $f->{config}{issuer}, aud => $f->{config}{audience}, sub => 'alice',
    iat => time - 1, nbf => time - 1, exp => time + 600, scope => 'mcp:read', role => 'user', %claims};
  return encode_jwt(payload => $payload, alg => 'RS256', key => $f->{key}, extra_headers => {typ => 'at+jwt'});
}
sub client ($f, %claims) {
  return MCP::Client->new(ua => $f->{t}->ua, url => $f->{t}->ua->server->url->path('/mcp'),
    headers => {Authorization => 'Bearer ' . token($f, %claims)}, capabilities => {elicitation => {form => {}}});
}
1;
