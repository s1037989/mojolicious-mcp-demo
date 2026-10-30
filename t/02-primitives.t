use Mojo::Base -strict, -signatures;
use Test::More;
use lib 't/lib';
use TestSupport qw(fixture client);
use Mojo::Util qw(b64_decode);
use Compress::Raw::Zlib qw(crc32);

my $f = fixture;
my $reader = client($f);
my $admin = client($f, role => 'admin', scope => 'mcp:read mcp:write mcp:admin');
subtest 'Discovery and schema validation' => sub {
  ok grep($_ eq '2026-07-28', @{$reader->discover->{supportedVersions}}), 'documented protocol revision advertised';
  is $reader->call_tool('echo', {message => 'hello'})->{content}[0]{text}, 'hello', 'plain string becomes text';
  for my $args ({}, {message => ''}, {message => 123}, {message => 'ok', extra => 'rejected'}) {
    eval { $reader->call_tool('echo', $args) };
    like $@, qr/-32602: Invalid arguments/, 'invalid arguments rejected before handler';
  }
  is $reader->call_tool('divide', {numerator => 6, denominator => 2})->{content}[0]{text}, '3', 'text_result';
  ok $reader->call_tool('divide', {numerator => 6, denominator => 0})->{isError}, 'recoverable error result';
  my $version = $reader->call_tool('perl_version');
  is $version->{structuredContent}{version}, "$^V", 'structured result validated';
  ok $admin->call_tool('broken_contract')->{isError}, 'invalid output becomes tool error';
  eval { $admin->call_tool('exception_demo') };
  like $@, qr/-32603: Internal error/, 'exception becomes protocol error';
  unlike $@, qr/DEMO_INTERNAL_DETAIL/, 'internal exception detail withheld';
};
subtest 'Every result constructor' => sub {
  my %expected = (text => 'text', error => 'text', image => 'image', audio => 'audio', link => 'resource_link');
  for my $kind (sort keys %expected) {
    my $r = $reader->call_tool('result_demo', {kind => $kind});
    is $r->{content}[0]{type}, $expected{$kind}, "$kind result type";
    is !!$r->{isError}, $kind eq 'error' ? !!1 : !!0, "$kind error flag";
    like b64_decode($r->{content}[0]{data}), qr/^\x89PNG\r\n\x1a\n/, 'PNG bytes encoded' if $kind eq 'image';
    like b64_decode($r->{content}[0]{data}), qr/^RIFF.{4}WAVE/s, 'WAV bytes encoded' if $kind eq 'audio';
    is $r->{content}[0]{uri}, 'demo:///handbook', 'resource pointer' if $kind eq 'link';
  }
};
subtest 'Prompts, resources and cache hints' => sub {
  is $reader->get_prompt('explain_module', {module => 'Mojo::UserAgent'})->{messages}[0]{role}, 'user', 'default user prompt';
  is $reader->get_prompt('mentor')->{messages}[0]{role}, 'assistant', 'explicit assistant role';
  eval { $reader->get_prompt('explain_module') };
  like $@, qr/-32602/, 'required prompt argument enforced';
  my $text = $reader->read_resource('demo:///handbook');
  like $text->{contents}[0]{text}, qr/Tools are/, 'text resource';
  is $text->{ttlMs}, 3_600_000, 'milliseconds in resource cache TTL';
  is $text->{cacheScope}, 'private', 'scoped resource has private cache hint';
  is $reader->list_tools->{cacheScope}, 'private', 'caller dependent tool list private';
  is $reader->list_prompts->{cacheScope}, 'private', 'caller dependent prompt list private';
  is $reader->list_resources->{cacheScope}, 'private', 'caller dependent resource list private';
  my $binary = $reader->read_resource('demo:///pixel.png');
  like b64_decode($binary->{contents}[0]{blob}), qr/^\x89PNG/, 'binary_resource uses blob';
  my $png = b64_decode($binary->{contents}[0]{blob});
  for (my $pos = 8; $pos < length($png);) {
    my $length = unpack 'N', substr($png, $pos, 4);
    my $chunk = substr($png, $pos + 4, $length + 4);
    is unpack('N', substr($png, $pos + 8 + $length, 4)), crc32($chunk), 'PNG chunk checksum valid';
    $pos += 12 + $length;
  }
  is $reader->read_resource('demo:///me')->{ttlMs}, 0, 'caller resource must be revalidated';
  like $reader->read_resource('demo:///me')->{contents}[0]{text}, qr/alice/, 'caller-specific content';
};
done_testing;
