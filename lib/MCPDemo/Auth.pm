package MCPDemo::Auth;
use Mojo::Base -base, -signatures;
use Crypt::JWT qw(decode_jwt);
use Crypt::PK::RSA;
use Scalar::Util qw(looks_like_number);

has 'config';
has public_key => sub ($self) {
  my $pem = $self->config->{public_key};
  my $key = Crypt::PK::RSA->new(\$pem);
  die "Configure an RSA public key of at least 2048 bits\n" if $key->is_private || $key->size < 256;
  return $key;
};

# Token verification belongs to the application, not MCP. All identity and
# permissions originate in signed claims from the configured trusted issuer.
sub authenticate ($self, $c) {
  my $header = $c->req->headers->authorization // '';
  return undef unless length($header) < 16384 && $header =~ /\ABearer[ \t]+([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)\z/i;
  return undef unless my $claims = $self->validate_token($1);
  $c->stash(role => $claims->{role});
  return {principal => $claims->{sub}, scopes => $claims->{scopes}};
}

sub validate_token ($self, $token) {
  my $config = $self->config;
  my $claims = eval {
    decode_jwt(
      token => $token, key => $self->public_key, accepted_alg => ['RS256'],
      verify_typ => 'at+jwt', verify_iss => $config->{issuer}, verify_aud => $config->{audience},
      verify_exp => 1, verify_iat => 1, leeway => 0
    );
  };
  # Never send validation exceptions, token contents or signing material to clients.
  return undef unless ref $claims eq 'HASH';
  return undef unless defined($claims->{sub}) && !ref($claims->{sub})
    && $claims->{sub} =~ /\A[^\x00-\x20\x7f]{1,200}\z/;
  for my $name (qw(exp iat)) {
    return undef unless defined $claims->{$name} && !ref($claims->{$name}) && looks_like_number($claims->{$name});
  }
  return undef unless $claims->{exp} > $claims->{iat};
  return undef if exists $claims->{nbf} && (ref($claims->{nbf}) || !looks_like_number($claims->{nbf}));
  my $scope = $claims->{scope} // '';
  return undef if ref($scope) || $scope !~ /\A(?:[A-Za-z0-9:._\/-]+(?: [A-Za-z0-9:._\/-]+)*)?\z/;
  my $role = $claims->{role} // 'user';
  return undef if ref $role || $role !~ /\A(?:user|admin)\z/;
  if (my $revoked = $config->{revoked_jti}) {
    return undef unless ref($revoked) eq 'ARRAY';
    return undef if ref($claims->{jti});
    return undef if grep { $_ eq ($claims->{jti} // '') } @$revoked;
  }
  return {sub => "$claims->{sub}", scopes => [grep {length} split / /, $scope], role => $role};
}
1;
