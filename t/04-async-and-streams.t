use Mojo::Base -strict, -signatures;
use Test::More;
use lib 't/lib';
use TestSupport qw(fixture client);
use MCP::Constants qw(META_LOG_LEVEL PROTOCOL_VERSION);
use Mojo::IOLoop;
use Mojo::JSON qw(decode_json true);
use Mojo::Log;
use Mojo::Promise;

my $f = fixture;
my $reader = client($f);
sub headers ($client, $name = 'count_steps') {
  return {%{$client->headers}, 'MCP-Protocol-Version' => PROTOCOL_VERSION, 'Mcp-Method' => 'tools/call', 'Mcp-Name' => $name};
}
sub settle ($delay = 0.05) {
  my $p = Mojo::Promise->new;
  Mojo::IOLoop->timer($delay => sub { $p->resolve });
  $p->wait;
}
subtest 'Progress and log level negotiated per request' => sub {
  my @messages;
  $reader->on(notification => sub ($client, $message) { push @messages, $message });
  my $request = $reader->build_request('tools/call', {name => 'count_steps', arguments => {steps => 3},
    _meta => {progressToken => 'progress-test', META_LOG_LEVEL() => 'info'}});
  my $result = $reader->send_request($request);
  is $result->{result}{content}[0]{text}, 'Completed 3 steps', 'promise resolves to final result';
  my @progress = grep {$_->{method} eq 'notifications/progress'} @messages;
  is_deeply [map {$_->{params}{progress}} @progress], [1, 2, 3], 'progress notifications delivered';
  is $progress[0]{params}{progressToken}, 'progress-test', 'progress token echoed';
  my @logs = grep {$_->{method} eq 'notifications/message'} @messages;
  is scalar @logs, 2, 'info start and finish logs';
  ok !grep($_->{params}{level} eq 'debug', @logs), 'debug filtered at info level';
  @messages = ();
  $reader->call_tool('count_steps', {steps => 1});
  is scalar @messages, 0, 'no unsolicited progress or logs';
};
subtest 'Other HTTP requests complete while a counter is running' => sub {
  my $ua = $f->{t}->ua;
  my $tx = $ua->build_tx(POST => $reader->url => headers($reader) => json =>
    $reader->build_request('tools/call', {name => 'count_steps', arguments => {steps => 4}}));
  my ($counter_finished, $health_finished, $early_health) = (0, 0, 0);
  my $count = $ua->start_p($tx)->then(sub ($done) { $counter_finished = 1 });
  my $health = $ua->get_p($ua->server->url->path('/'))->then(sub ($done) {
    $health_finished = $done->res->is_success;
    $early_health = !$counter_finished;
  });
  Mojo::Promise->all($count, $health)->wait;
  ok $health_finished, 'another request served';
  ok $early_health, 'served before counter finished';
  ok $counter_finished, 'counter also finished';
};
subtest 'HTTP disconnect cancels outstanding timer work' => sub {
  my @log;
  my $logger = Mojo::Log->new(level => 'debug');
  $logger->unsubscribe('message');
  $logger->on(message => sub ($log, $level, @lines) { push @log, @lines });
  $f->{t}->app->mcp->log($logger);
  my $tx = $reader->ua->build_tx(POST => $reader->url => headers($reader) => json =>
    $reader->build_request('tools/call', {name => 'count_steps', arguments => {steps => 20}, _meta => {progressToken => 'cancel'}}));
  my $got_progress = 0;
  my $stop = Mojo::Promise->new;
  my $guard = Mojo::IOLoop->timer(4 => sub { $stop->resolve });
  $tx->res->content->on(sse => sub ($content, $event = undef) {
    return unless $event && $event->{text};
    my $message = decode_json($event->{text});
    return unless ($message->{method} // '') eq 'notifications/progress';
    ++$got_progress;
    Mojo::IOLoop->remove($tx->connection);
    $stop->resolve;
  });
  $reader->ua->start_p($tx)->catch(sub { });
  $stop->wait;
  Mojo::IOLoop->remove($guard);
  settle;
  is $got_progress, 1, 'client disconnects after first progress event';
  ok grep(/Counter cancelled; timer removed/, @log), 'cancellation handler ran and released timer';
  settle 0.15;
  ok !grep(/Counter finished/, @log), 'cancelled counter never completed';
};
subtest 'Subscriptions disabled by default' => sub {
  ok !$reader->discover->{capabilities}{tools}{listChanged}, 'no global notification capability by default';
  my $res = $reader->send_request($reader->build_request('subscriptions/listen', {notifications => {toolsListChanged => true}}));
  is $res->{error}{code}, -32601, 'subscription method unavailable';
};
subtest 'Optional single-process notification stream' => sub {
  my $stream = fixture(streaming => 1);
  my $viewer = client($stream);
  my $admin = client($stream, role => 'admin', scope => 'mcp:admin mcp:read');
  ok $viewer->discover->{capabilities}{tools}{listChanged}, 'notification capability advertised';
  my @messages;
  # Schedule a separate authenticated call after the subscription is acknowledged.
  $viewer->listen({toolsListChanged => true}, sub ($message) {
    push @messages, $message;
    if (@messages == 1) {
      my $request = $admin->build_request('tools/call', {name => 'announce_tools', arguments => {}});
      my $tx = $admin->ua->build_tx(POST => $admin->url => headers($admin, 'announce_tools') => json => $request);
      $admin->ua->start_p($tx)->catch(sub { die 'Announcement request failed' });
    }
    return @messages < 2;
  });
  is $messages[0]{method}, 'notifications/subscriptions/acknowledged', 'subscription acknowledged';
  is $messages[1]{method}, 'notifications/tools/list_changed', 'invalidation delivered';
  settle;
  is scalar(keys %{$stream->{t}->app->mcp->transport->subscriptions}), 0, 'subscription removed after disconnect';
};
done_testing;
