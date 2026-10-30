use Mojo::Base -strict, -signatures;
use Test::More;
use IPC::Run qw(run timeout);
use MCP::Client;
use Mojo::JSON qw(decode_json encode_json);

my $client = MCP::Client->new;
my @requests = (
  $client->build_request('server/discover'),
  $client->build_request('tools/list'),
  $client->build_request('tools/call', {name => 'echo', arguments => {message => 'stdio works'}}),
  $client->build_request('tools/call', {name => 'whoami', arguments => {}})
);
my $input = join '', map {encode_json($_) . "\n"} @requests;
my ($out, $err);
ok run([$^X, 'script/stdio-server'], \$input, \$out, \$err, timeout(10)), 'stdio process exits successfully';
my @lines = grep {length} split /\n/, $out;
is scalar @lines, 4, 'exactly one JSON response per request; no stdout logging';
my @messages = map {decode_json($_)} @lines;
my %by_id = map {$_->{id} => $_} @messages;
is $by_id{3}{result}{content}[0]{text}, 'stdio works', 'stdio tool call';
is $by_id{4}{result}{structuredContent}{principal}, 'local-process', 'stdio has local identity';
ok !grep($_->{name} eq 'admin_status', @{$by_id{2}{result}{tools}}), 'no HTTP admin role means smallest admin view';
ok grep($_->{name} eq 'publish_preview', @{$by_id{2}{result}{tools}}), 'stdio trusts process owner; scopes do not enforce auth';
done_testing;
