#!/usr/bin/perl
# the defaults of an agent's enrollment: the name is a random UUID (version 4) when none is given,
# and the tags are the names of its programs (a path's last part, short lower-case words only)
use strict; use warnings;

use Test::More;
use FindBin;
use lib "$FindBin::Bin/..";

require "$FindBin::Bin/../remote_agent.pm";

my %seen;
for (1 .. 50) {
    my $n = remote_agent::new_name();
    like($n, qr/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/, "a UUID version 4: $n");
    $seen{$n}++;
}
is(scalar keys %seen, 50, "every name is new");

my @t = remote_agent::tags_of_programs('bash', '/usr/bin/perl', 'arduino-cli', 'python3', 'usb_logger', 'Bad', 'bash');
is_deeply(\@t, ['bash', 'perl', 'arduino-cli', 'python3'], "the tags are the programs' names, each once; invalid ones left out");
is_deeply([remote_agent::tags_of_programs()], [], "no programs, no tags");

done_testing();
