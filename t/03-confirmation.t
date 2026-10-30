use Mojo::Base -strict, -signatures;
use Test::More;
use lib 't/lib';
use TestSupport qw(fixture client);
use Mojo::JSON qw(false true);
use MCP::Server::Context;

my $f = fixture;
my $alice = client($f, scope => 'mcp:read mcp:write');
my $bob = client($f, sub => 'bob', scope => 'mcp:read mcp:write');
my $first = $alice->call_tool('publish_preview', {release => 'approved-release'});
is $first->{resultType}, 'input_required', 'first call requests input';
is $first->{inputRequests}{confirm}{method}, 'elicitation/create', 'elicitation request';
ok my $state = $first->{requestState}, 'sealed request state returned';
my $accept = {confirm => {action => 'accept', content => {ok => true}}};
my $retry = $alice->call_tool('publish_preview', {release => 'different-release'}, {request_state => $state, input_responses => $accept});
like $retry->{content}[0]{text}, qr/would publish approved-release for alice/, 'uses approved sealed release and principal';
unlike $retry->{content}[0]{text}, qr/different-release/, 'retry arguments cannot replace approved target';
for my $action (qw(decline cancel)) {
  like $alice->call_tool('publish_preview', {release => 'v1'}, {
    request_state => $state, input_responses => {confirm => {action => $action}}
  })->{content}[0]{text}, qr/cancelled/, "$action honored";
}
for my $ok (false, 'false', 'true', 1) {
  like $alice->call_tool('publish_preview', {release => 'v1'}, {
    request_state => $state, input_responses => {confirm => {action => 'accept', content => {ok => $ok}}}
  })->{content}[0]{text}, qr/cancelled/, 'only JSON true approves';
}
my $tampered = $state;
substr($tampered, 0, 1) = substr($tampered, 0, 1) eq 'X' ? 'Y' : 'X';
is $alice->call_tool('publish_preview', {release => 'v1'}, {request_state => $tampered, input_responses => $accept})->{resultType},
  'input_required', 'tampered state asks again';
is $bob->call_tool('publish_preview', {release => 'v1'}, {request_state => $state, input_responses => $accept})->{resultType},
  'input_required', 'another principal cannot use approval state';
my $server = $f->{t}->app->mcp;
my $context = MCP::Server::Context->new(state_secret => $f->{config}{state_secret}, state_timeout => -1,
  principal => 'alice', state_binding => "tools/call\0publish_preview");
my $expired = $context->seal_state({release => 'v1'});
is $alice->call_tool('publish_preview', {release => 'v1'}, {request_state => $expired, input_responses => $accept})->{resultType},
  'input_required', 'expired state asks again';
$context->state_timeout(300)->state_binding("tools/call\0different_tool");
my $other_tool = $context->seal_state({release => 'v1'});
is $alice->call_tool('publish_preview', {release => 'v1'}, {request_state => $other_tool, input_responses => $accept})->{resultType},
  'input_required', 'state bound to another tool rejected';
my $other_server = MCPDemo::Server->build(state_secret => $f->{config}{state_secret});
my $verify = MCP::Server::Context->new(state_secret => $other_server->state_secret, principal => 'alice',
  state_binding => "tools/call\0publish_preview", raw_request_state => $state);
is $verify->request_state->{release}, 'approved-release', 'another worker can verify shared-secret state';
$alice->capabilities({});
ok $alice->call_tool('publish_preview', {release => 'v1'})->{isError}, 'client without elicitation capability receives error';
done_testing;
