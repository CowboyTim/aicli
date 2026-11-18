#!/usr/bin/perl
# auth.pl: the account files. The four files of /etc that PAM and the account tools use are
# copied to the state (the volume) after a change, and copied back at a start; the admin
# commands refuse bad names and roles before any change. The system commands are recorded
# here, not run (no root in the tests), and /etc is a directory of the test.
use strict; use warnings;

use Test::More;
use FindBin;
use File::Temp ();

require "$FindBin::Bin/../auth.pl";

my $dir = File::Temp::tempdir("aicli_accounts_XXXXXX", TMPDIR => 1, CLEANUP => 1);
my $etc = "$dir/etc";
my $state = "$dir/state";
mkdir $etc or die "mkdir: $!";
local $ENV{AI_AUTH_ETC} = $etc;
local $ENV{AI_AUTH_STATE} = $state;

sub write_file {
    my ($f, $data) = @_;
    open(my $fh, '>', $f) or die "$f: $!";
    print {$fh} $data;
    close $fh;
}
sub read_file { my ($f) = @_; open(my $fh, '<', $f) or return undef; local $/; my $d = <$fh>; close $fh; return $d }

ok(valid_role('aicli-user'), "a role of the web");
ok(!valid_role('root'), "no other group is a role");
ok(!valid_role('aicli-'), "a role has a name after the prefix");
ok(!valid_role('aicli-a/b'), "and no slash");

# the image's files, then the admin's account in them
my %image = (
    passwd => "root:x:0:0:root:/root:/bin/bash\nalice:x:1001:1001::/home/alice:/usr/sbin/nologin\n",
    group => "root:x:0:\nalice:x:1001:\naicli-user:x:1002:alice\n",
    shadow => "root:*:19000:0:99999:7:::\nalice:\$6\$abc:19001:0:99999:7:::\n",
    gshadow => "root:::\nalice:!::\naicli-user:!::alice\n",
);
for my $f (keys %image) { write_file("$etc/$f", $image{$f}) }

is(restore_accounts(), 0, "no state yet: nothing is copied back");
save_accounts();
for my $f (keys %image) {
    is(read_file("$state/$f"), $image{$f}, "the state has $f");
    is((stat "$state/$f")[2] & 0777, 0600, "$f is kept with mode 0600");
}

# a rebuilt container: the files are the image's again, without the admin's account
write_file("$etc/passwd", "root:x:0:0:root:/root:/bin/bash\n");
write_file("$etc/shadow", "root:*:19000:0:99999:7:::\n");
write_file("$etc/group", "root:x:0:\n");
write_file("$etc/gshadow", "root:::\n");
is(restore_accounts(), 1, "at the start the state is copied back");
for my $f (keys %image) {
    is(read_file("$etc/$f"), $image{$f}, "$f has the admin's accounts again");
}
is((stat "$etc/passwd")[2] & 0777, 0644, "passwd is 0644");
is((stat "$etc/shadow")[2] & 0777, 0640, "shadow is 0640");

# the admin commands refuse before any change, and run nothing for them
my @cmds;
{
    local $main::RUN = sub { push @cmds, [@_]; return 1 };
    eval { user_command('add', '../etc', 'aicli-user') }; like($@, qr/a user name/, "add: a path is no user name");
    eval { user_command('add', 'zz-auth-test-8', 'root') }; like($@, qr/is no role/, "add: a group that is no role");
    eval { user_command('add', 'nobody') }; like($@, qr/exists/, "add: an existing account");
    eval { user_command('role', 'add', 'no-such-user-xyz', 'aicli-user') }; like($@, qr/no account/, "role: an unknown account");
    eval { user_command('role', 'add', 'nobody', 'root') }; like($@, qr/is no role/, "role: a bad role");
    eval { user_command('frob') }; like($@, qr/user add/, "an unknown command shows the usage");
}
is_deeply(\@cmds, [], "and no system command ran for any of them");

done_testing();
