#!/usr/bin/perl
# the account ID of a login: a UUID in the passwd comment (GECOS), its "other" subfield, as
# aicli=<uuid> (the fifth subfield, after full name, room, work phone, home phone). Made at
# the first need, kept (usermod -c keeps the other subfields), read back without its dashes.
# The passwd is a table here, and usermod a stub that writes to it.
use strict; use warnings;
use Test::More;
use FindBin;
require "$FindBin::Bin/../auth.pl";
no warnings 'once';

my %gecos;   # login => the comment (GECOS)
my @usermod;
{
    no warnings 'redefine';
    *main::gecos_of = sub { my ($n) = @_; return exists $gecos{$n} ? $gecos{$n} : undef };
    *main::save_accounts = sub { 1 };
    $main::RUN = sub {
        my @cmd = @_;
        push @usermod, [@cmd];
        if ($cmd[0] eq 'usermod' and $cmd[1] eq '-c') { $gecos{$cmd[3]} = $cmd[2] }
        return 1;
    };
}

my $uuid = qr/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/;

# the UUID: version 4, RFC 4122, unique
my @u = map {new_uuid()} 1 .. 20;
like($_, qr/\A$uuid\z/, "a UUID: $_") for @u[0, 1];
is(substr($u[0], 14, 1), '4', "version 4");
like(substr($u[0], 19, 1), qr/[89ab]/, "the RFC 4122 variant");
is(scalar(keys %{{map {($_ => 1)} @u}}), 20, "every UUID is different");

# the comment and the ID in it
$gecos{alice} = '';
is(account_id('alice'), undef, "a login with an empty comment has no account ID yet");
is(account_id('nobody'), undef, "a login that is not in the passwd has none");
$gecos{bob} = "Bob Smith,,,,aicli=3f2a1b4c-5d6e-4f70-8192-a3b4c5d6e7f8";
is(account_id('bob'), '3f2a1b4c5d6e4f708192a3b4c5d6e7f8', "the ID of the fifth subfield, without the dashes");
$gecos{carol} = "Carol,Room 4,555,666,Some other;aicli=3f2a1b4c-5d6e-4f70-8192-a3b4c5d6e7f8;x=y";
is(account_id('carol'), '3f2a1b4c5d6e4f708192a3b4c5d6e7f8', "among other key=value entries of that subfield");
$gecos{dave} = "aicli=3f2a1b4c-5d6e-4f70-8192-a3b4c5d6e7f8";
is(account_id('dave'), undef, "an ID in the first subfield is not the account ID (the fifth is where it is kept)");

# making it: the fifth subfield, the others kept
%gecos = (alice => '');
@usermod = ();
my $id = ensure_account_id('alice');
like($id, qr/\A[0-9a-f]{32}\z/, "a new account ID, without dashes");
is($gecos{alice}, ",,,,aicli=" . join('-', substr($id, 0, 8), substr($id, 8, 4), substr($id, 12, 4), substr($id, 16, 4), substr($id, 20)),
    "in the fifth subfield of an empty comment");
is(scalar(@usermod), 1, "usermod once");
is(ensure_account_id('alice'), $id, "the same ID the next time, no usermod");
is(scalar(@usermod), 1, "and no second usermod");

$gecos{erin} = "Erin Jones,Room 2,555-1234,555-9876,a note";
my $eid = ensure_account_id('erin');
is(account_id('erin'), $eid, "the ID of erin");
like($gecos{erin}, qr/\AErin Jones,Room 2,555-1234,555-9876,a note;aicli=$uuid\z/, "the other subfields kept, the note too");

$gecos{frank} = "Frank";
ensure_account_id('frank');
like($gecos{frank}, qr/\AFrank,,,,aicli=$uuid\z/, "a comment with only the name: the subfields padded to the fifth");

eval { ensure_account_id('nobody') };
like($@, qr/no account nobody/, "a login that is not in the passwd: refused");

done_testing();
