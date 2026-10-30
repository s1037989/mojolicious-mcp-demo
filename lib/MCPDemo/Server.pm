package MCPDemo::Server;
use Mojo::Base -strict, -signatures;
use MCP::Server;
use Mojo::IOLoop;
use Mojo::JSON qw(encode_json false true);
use Mojo::Promise;
use Mojo::Util qw(b64_decode);

# A deterministic one-pixel PNG and 20 ms of unsigned 8-bit silence. No files,
# subprocesses, external services or extra image/audio libraries are needed.
sub png { b64_decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=') }
sub wav {
  my $samples = chr(128) x 160;
  return 'RIFF' . pack('V', 36 + length $samples) . 'WAVEfmt '
    . pack('VvvVVvv', 16, 1, 1, 8000, 8000, 1, 8) . 'data' . pack('V', length $samples) . $samples;
}
sub schema ($properties = {}, $required = []) {
  return {type => 'object', properties => $properties, required => $required, additionalProperties => false};
}

sub build ($class, %options) {
  my $server = MCP::Server->new(
    name => 'Mojolicious MCP demonstration', version => '1.0.0',
    instructions => 'Use handbook for orientation. All publish operations are simulations. Ask the user before confirming a publish.',
    state_secret => $options{state_secret}, state_timeout => $options{state_timeout} // 300,
    cache_scope => 'private'
  );
  $server->log($options{log}) if $options{log};
  my $read = ['mcp:read'];

  $server->tool(
    name => 'echo', description => 'Repeat a short message verbatim.', scopes => $read,
    input_schema => schema({message => {type => 'string', minLength => 1, maxLength => 1000}}, ['message']),
    code => sub ($tool, $args) { return $args->{message} }
  );
  $server->tool(
    name => 'divide', description => 'Divide two numbers. Division by zero returns a recoverable tool error.', scopes => $read,
    input_schema => schema({numerator => {type => 'number'}, denominator => {type => 'number'}}, [qw(numerator denominator)]),
    code => sub ($tool, $args) {
      return $tool->text_result('The denominator must not be zero.', 1) if $args->{denominator} == 0;
      return $tool->text_result($args->{numerator} / $args->{denominator});
    }
  );
  $server->tool(
    name => 'perl_version', description => 'Read the server Perl version as validated structured data.', scopes => $read,
    input_schema => schema(),
    output_schema => schema({version => {type => 'string'}, release => {type => 'number'}}, [qw(version release)]),
    code => sub ($tool, $args) { $tool->structured_result({version => "$^V", release => 0 + $]}) }
  );
  $server->tool(
    name => 'whoami', description => 'Read the identity and scopes of this request; no client supplied identity is accepted.',
    input_schema => schema(),
    code => sub ($tool, $args) {
      my $context = $tool->context;
      return $tool->structured_result({
        principal => $context->principal // 'local-process', scopes => $context->scopes // [],
        transport => $context->controller ? 'http' : 'stdio',
        role => $context->controller ? $context->controller->stash('role') : 'local'
      });
    }
  );
  $server->tool(
    name => 'result_demo', description => 'Return sample text, an expected error, PNG image, WAV audio or handbook resource link.',
    scopes => $read, input_schema => schema({kind => {type => 'string', enum => [qw(text error image audio link)]}}, ['kind']),
    code => sub ($tool, $args) {
      my $kind = $args->{kind};
      return $tool->image_result(png(), {mime_type => 'image/png'}) if $kind eq 'image';
      return $tool->audio_result(wav()) if $kind eq 'audio';
      return $tool->resource_link_result('demo:///handbook', {name => 'handbook'}) if $kind eq 'link';
      return $tool->text_result('An expected demonstration error.', 1) if $kind eq 'error';
      return $tool->text_result('Hello from MCP::Tool.');
    }
  );
  $server->tool(
    name => 'count_steps', description => 'Run a bounded asynchronous counter with optional progress and logs. Disconnect to cancel.',
    scopes => $read, input_schema => schema({steps => {type => 'integer', minimum => 1, maximum => 20}}, ['steps']),
    code => sub ($tool, $args) {
      # Primitive->context is dynamically scoped: capture it before any timer.
      my $context = $tool->context;
      my $promise = Mojo::Promise->new;
      my ($done, $id, $cancel_cb) = (0);
      $context->notify_log(info => 'Starting asynchronous counter');
      $id = Mojo::IOLoop->recurring(0.1 => sub {
        return if $context->is_cancelled;
        $context->notify_progress(++$done, $args->{steps}, "Completed step $done");
        $context->notify_log(debug => {step => $done});
        return if $done < $args->{steps};
        Mojo::IOLoop->remove($id);
        $context->unsubscribe(cancelled => $cancel_cb);
        $cancel_cb = undef; # Break the callback's self-reference.
        $context->notify_log(info => 'Counter finished');
        $promise->resolve("Completed $done steps");
      });
      $cancel_cb = sub ($ctx) {
        Mojo::IOLoop->remove($id);
        $ctx->unsubscribe(cancelled => $cancel_cb);
        $cancel_cb = undef;
        # Resolve and release the promise chain even though transport is closed.
        $server->log->debug('Counter cancelled; timer removed');
        $promise->resolve($tool->text_result('Counter cancelled.', 1));
      };
      $context->on(cancelled => $cancel_cb);
      return $promise->catch(sub ($error) {
        Mojo::IOLoop->remove($id);
        $context->unsubscribe(cancelled => $cancel_cb);
        $cancel_cb = undef;
        $server->log->error('Counter failed');
        return $tool->text_result('The counter could not finish.', 1);
      });
    }
  );
  $server->tool(
    name => 'publish_preview', description => 'Simulate publishing a named release after explicit confirmation. No release is changed.',
    scopes => ['mcp:write'],
    input_schema => schema({release => {type => 'string', pattern => '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'}}, ['release']),
    code => sub ($tool, $args) {
      my $ctx = $tool->context;
      my $caps = $ctx->client_capabilities // {};
      return $tool->text_result('This client must declare elicitation.form support to confirm a publish preview.', 1)
        unless ref($caps->{elicitation}) eq 'HASH' && exists $caps->{elicitation}{form};
      my $state = $ctx->request_state;
      my $answer = ($ctx->input_responses // {})->{confirm};
      if ($state && ref($answer) eq 'HASH') {
        my $action = $answer->{action} // '';
        return $tool->text_result('Publish preview cancelled.') if $action eq 'decline' || $action eq 'cancel';
        if ($action eq 'accept' && ref($answer->{content}) eq 'HASH') {
          my $ok = $answer->{content}{ok};
          # Require an actual JSON boolean true, not a string such as "false".
          return $tool->text_result("SIMULATION: would publish $state->{release} for " . ($ctx->principal // 'local-process'))
            if defined($ok) && encode_json($ok) eq 'true';
          return $tool->text_result('Publish preview cancelled.');
        }
      }
      # request_state verifies HMAC, expiration, principal AND tool binding.
      # Retry arguments are unsealed; only the sealed release is approved.
      return $tool->input_required({confirm => {
        method => 'elicitation/create', params => {
          message => "Simulate publishing release $args->{release}?",
          requestedSchema => schema({ok => {type => 'boolean', title => 'Approve this simulation?'}}, ['ok'])
        }
      }}, {release => $args->{release}});
    }
  );

  # All three primitive-list events are authorization filters on invocation too.
  $server->tool(
    name => 'admin_status', scopes => ['mcp:admin'], input_schema => schema(),
    description => 'Read an administrator-only demonstration status. Requires admin role and scope.',
    code => sub ($tool, $args) { 'Administrator view: demonstration service is healthy.' }
  );
  $server->tool(
    name => 'broken_contract', scopes => ['mcp:admin'], input_schema => schema(),
    description => 'Deliberately return invalid structured output to demonstrate output-schema enforcement.',
    output_schema => schema({count => {type => 'integer'}}, ['count']),
    code => sub ($tool, $args) { $tool->structured_result({count => 'not-an-integer'}) }
  );
  $server->tool(
    name => 'exception_demo', scopes => ['mcp:admin'], input_schema => schema(),
    description => 'Deliberately throw a harmless sample exception to demonstrate sanitized protocol errors.',
    code => sub ($tool, $args) { die "DEMO_INTERNAL_DETAIL: simulated backend exception\n" }
  );
  $server->tool(
    name => 'announce_tools', scopes => ['mcp:admin'], input_schema => schema(),
    description => 'Broadcast a tools-list invalidation notification in optional single-process streaming mode.',
    code => sub ($tool, $args) {
      return $tool->text_result('Subscriptions are disabled; set streaming=true and run one daemon process.', 1)
        unless $server->transport && $server->transport->notifications;
      $server->notify_list_changed('tools');
      return 'Sent a tools-list invalidation signal; the registered list is unchanged.';
    }
  );

  $server->prompt(
    name => 'explain_module', description => 'A user-selected prompt asking for a concise explanation of a Perl module.',
    scopes => $read, arguments => [{name => 'module', description => 'Perl module name', required => 1}],
    code => sub ($prompt, $args) { "Explain what $args->{module} does, then show a short Perl example using it." }
  );
  $server->prompt(
    name => 'mentor', scopes => $read, description => 'An explicit assistant-role prompt.',
    code => sub ($prompt, $args) { $prompt->text_prompt('I am ready to help you understand this Perl code.', 'assistant') }
  );
  $server->prompt(
    name => 'admin_review', scopes => ['mcp:admin'], description => 'Administrator-only review prompt.',
    code => sub ($prompt, $args) { 'Review the authentication policy and scope assignments for this MCP server.' }
  );
  $server->resource(
    uri => 'demo:///handbook', name => 'handbook', mime_type => 'text/plain', scopes => $read,
    description => 'Orientation to the demonstration. This URI is a resource identifier, not a filesystem path.',
    cache_ttl => 3_600_000,
    code => sub ($resource) {
      return "Tools are model-selected functions. Prompts are user-selected templates. Resources are client-readable context.\n"
        . "HTTP authenticates every request. read/write/admin scopes and admin role are independent.\n"
        . "publish_preview is a simulation. count_steps supports progress, logs and cancellation.\n";
    }
  );
  $server->resource(
    uri => 'demo:///pixel.png', name => 'pixel', description => 'A binary resource with base64-encoded PNG contents.',
    mime_type => 'image/png', scopes => $read, cache_ttl => 3_600_000,
    code => sub ($resource) { $resource->binary_resource(png()) }
  );
  $server->resource(
    uri => 'demo:///me', name => 'current_caller', description => 'The current caller; never shared between users.',
    scopes => $read, cache_scope => 'private', cache_ttl => 0,
    code => sub ($resource) { 'Current caller: ' . ($resource->context->principal // 'local-process') }
  );
  $server->resource(
    uri => 'demo:///admin', name => 'admin', description => 'Administrator-only sample document.', scopes => ['mcp:admin'],
    code => sub ($resource) { 'Administrator document (demonstration data only).' }
  );
  my %admin = map { $_ => 1 } qw(admin_status broken_contract exception_demo announce_tools admin_review);
  for my $kind (qw(tools prompts resources)) {
    $server->on($kind => sub ($srv, $primitives, $context) {
      my $c = $context->controller;
      return if $c && ($c->stash('role') // '') eq 'admin';
      @$primitives = grep { !$admin{$_->name} && !($_->can('uri') && $_->uri eq 'demo:///admin') } @$primitives;
    });
  }
  return $server;
}
1;
