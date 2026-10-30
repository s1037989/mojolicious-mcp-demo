package MCPDemo::Config;
use Mojo::Base -strict, -signatures;
use Mojo::File qw(path);
use Mojo::JSON qw(decode_json);
use Mojo::URL;

sub root { path(__FILE__)->to_abs->dirname->dirname->dirname }

sub load ($class, $file = undef) {
  $file //= $ENV{MCP_DEMO_CONFIG} // root()->child('var', 'server.json');
  die "Missing server configuration; run perl script/demo-setup first\n" unless -f $file;
  my $config = decode_json(path($file)->slurp);
  die "Configuration must be a JSON object\n" unless ref $config eq 'HASH';
  for my $key (qw(public_key issuer audience base_url state_secret)) {
    die "Missing configuration: $key\n" unless defined $config->{$key} && !ref($config->{$key}) && length $config->{$key};
  }
  die "state_secret must contain at least 32 bytes\n" unless length($config->{state_secret}) >= 32;
  my $base = Mojo::URL->new($config->{base_url});
  die "base_url must be an absolute HTTP(S) origin, without a path\n"
    unless ($base->scheme // '') =~ /^https?$/ && $base->host && !$base->userinfo
      && !$base->query->to_string && !$base->fragment && $base->path->to_string =~ m{^/?$};
  $config->{base_url} =~ s{/$}{};
  die "audience must be the public MCP endpoint URL\n" unless $config->{audience} eq "$config->{base_url}/mcp";
  die "allowed_origins must be an array\n"
    if exists $config->{allowed_origins} && ref $config->{allowed_origins} ne 'ARRAY';
  $config->{allowed_origins} //= [$config->{base_url}];
  return $config;
}
1;
