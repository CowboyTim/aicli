#!/usr/bin/perl
# the passwords of the accounts are set by auth.pl itself: its rules (the length, printable,
# not the name), the hash (SHA-512 crypt, a random salt, the rounds), and the stored hash
# (chpasswd -e, a stand-in here). Nothing goes through the system's passwd.
use strict; use warnings;

use Test::More;
use FindBin;

require "$FindBin::Bin/../auth.pl";
no warnings 'once';

# the rules
like(password_problem('alice', 'short'), qr/shorter than 10/, "a short password is no good");
like(password_problem('alice', 'alice'), qr/shorter/, "the name, too short");
like(password_problem('alicealice', 'alicealice'), qr/the account name/, "the name itself is no password");
like(password_problem('alice', "ten chars\t"), qr/printable/, "a control character is no good");
is(password_problem('alice', 'a good long one'), undef, "a password of the rules is good");
{
    local $ENV{AI_AUTH_MINLEN} = 4;
    is(password_problem('alice', 'four'), undef, "the length comes from AI_AUTH_MINLEN");
}

# the hash: SHA-512 crypt, with the rounds, and it checks the password
my $hash = hash_password('a good long one');
like($hash, qr/\A\$6\$rounds=100000\$[.\/0-9A-Za-z]{16}\$[.\/0-9A-Za-z]{86}\z/, "a SHA-512 crypt hash with the rounds and a 16-character salt");
is(crypt('a good long one', $hash), $hash, "it checks the password it was made from");
isnt(crypt('another one here', $hash), $hash, "and not another one");
isnt(hash_password('a good long one'), $hash, "every hash has its own salt");

# set_password: asked twice, the rules, the hash given to chpasswd -e
my @cmds;
{
    local $main::RUN_IN = sub { push @cmds, [@_]; return 1 };
    local *STDIN;
    open(STDIN, '<', \"a good long one\na good long one\n") or die "stdin: $!";
    set_password('alice');
    is(scalar(@cmds), 1, "one system command");
    my ($input, @argv) = @{ $cmds[0] };
    is_deeply(\@argv, [qw(chpasswd -e)], "chpasswd -e stores it");
    like($input, qr/\Aalice:\$6\$rounds=100000\$/, "the input is name:hash");
    my ($hash) = $input =~ m/:(\S+)\n\z/;
    is(crypt('a good long one', $hash), $hash, "and the hash checks the password");
    unlike($input . join(' ', @argv), qr/a good long one/, "the password is in no argument, nor in the input");
}
{
    local $main::RUN_IN = sub { push @cmds, [@_]; return 1 };
    local *STDIN;
    open(STDIN, '<', \"a good long one\nanother good one\n") or die "stdin: $!";
    my $n = @cmds;
    eval { set_password('alice') };
    like($@, qr/the two passwords differ/, "two passwords that differ are refused");
    is(scalar(@cmds), $n, "and nothing is stored");
}
{
    local $main::RUN_IN = sub { push @cmds, [@_]; return 1 };
    local *STDIN;
    open(STDIN, '<', \"short\nshort\n") or die "stdin: $!";
    my $n = @cmds;
    eval { set_password('alice') };
    like($@, qr/shorter than 10/, "a password that breaks the rules is refused");
    is(scalar(@cmds), $n, "and nothing is stored");
}

done_testing();
