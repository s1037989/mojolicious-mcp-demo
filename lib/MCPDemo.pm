package MCPDemo;
use Mojo::Base 'Mojolicious', -signatures;
use MCPDemo::Auth;
use MCPDemo::Config;
use MCPDemo::Server;

sub startup ($self) {
  my $config = MCPDemo::Config->load;
  $self->secrets([$config->{state_secret}]);
  $self->max_request_size(1024 * 1024);
  my $auth = MCPDemo::Auth->new(config => $config);
  $auth->public_key; # Fail startup on a broken or private verification key.
  my $server = MCPDemo::Server->build(state_secret => $config->{state_secret}, log => $self->log);
  $self->helper(mcp => sub ($c) { $server });
  $self->helper(demo_auth => sub ($c) { $auth });
  $self->routes->get('/')->to(cb => sub ($c) {
    $c->render(json => {application => 'Mojolicious MCP demo', endpoint => '/mcp', documentation => 'README.md'});
  });
  my $metadata = sub ($c) {
    $c->render(json => $server->oauth_metadata(
      resource => $config->{audience}, authorization_servers => [$config->{issuer}],
      bearer_methods_supported => ['header'], resource_name => 'Mojolicious MCP demo'
    ));
  };
  # Publish the route-specific RFC 9728 URI plus the root alias from the MCP POD.
  $self->routes->get('/.well-known/oauth-protected-resource/mcp')->to(cb => $metadata);
  $self->routes->get('/.well-known/oauth-protected-resource')->to(cb => $metadata);
  $self->routes->any('/mcp')->to(cb => $server->to_action({
    auth => sub ($c) { $auth->authenticate($c) },
    metadata_url => "$config->{base_url}/.well-known/oauth-protected-resource/mcp",
    origins => $config->{allowed_origins}, streaming => $config->{streaming} ? 1 : 0
  }));
}
1;
