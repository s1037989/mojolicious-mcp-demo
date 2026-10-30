requires 'perl', '5.020';
requires 'MCP', '== 0.15';
requires 'Mojolicious', '9.41';
requires 'Crypt::JWT', '0.038';
requires 'CryptX', '0.087';
on test => sub { requires 'Test::More', '1.302'; };
