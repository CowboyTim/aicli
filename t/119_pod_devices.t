#!/usr/bin/perl
# the devices of a pod kind: the config's rules (what is refused), the device paths
# that exist at open (globs under /dev, usb ids through sysfs), their numbers, the groups
# that own them, and what the container spec gets. Real character devices (/dev/null,
# /dev/zero) stand in for the host's, behind symlinks in a temporary /dev and /sys.
use strict; use warnings;

use Test::More;
use FindBin;
use File::Temp ();
use File::Path ();
use Cwd ();
use JSON::XS ();

require "$FindBin::Bin/../broker.pl";

my $J = JSON::XS->new->canonical(1)->utf8;
my $tmp = Cwd::abs_path(File::Temp::tempdir("aicli_pdev_XXXXXX", TMPDIR => 1, CLEANUP => 1));
my $dev = "$tmp/dev";
my $sys = "$tmp/sys";
File::Path::make_path("$sys/bus/usb/devices/1-1", "$sys/bus/usb/devices/1-2", "$dev/bus/usb/001", "$dev/dri");
symlink('/dev/null', "$dev/ttyACM0") or die "symlink: $!";   # a board, plugged in
symlink('/dev/zero', "$dev/kfd") or die "symlink: $!";        # the ROCm compute node
symlink('/dev/null', "$dev/bus/usb/001/005") or die "symlink: $!"; # the usb meter's node

# a usb meter at bus 1, device 5, with its ids as sysfs has them (with the newline)
for my $f ([idVendor => "0483\n"], [idProduct => "003a\n"], [busnum => "1\n"], [devnum => "5\n"]) {
    open(my $fh, '>', "$sys/bus/usb/devices/1-1/$f->[0]") or die "file: $!";
    print {$fh} $f->[1];
    close $fh;
}
# another device (not a meter) on the same sysfs
open(my $other, '>', "$sys/bus/usb/devices/1-2/idVendor") or die; print {$other} "1234\n"; close $other;
open(my $other2, '>', "$sys/bus/usb/devices/1-2/idProduct") or die; print {$other2} "5678\n"; close $other2;

my %base = (root => $tmp, host_root => "$tmp/host", dev_root => $dev, sys_root => $sys,
    engine => "$tmp/none.sock", memory => '2g', pids => 512, userns => 'keep-id', images => ['x']);

# --- what the config may say -----------------------------------------------------------

my $refused = sub {
    my ($pods, $like) = @_;
    my $ok = eval { broker->new(%base, pods => $pods); 1 };
    ok(!$ok, "refused: $like");
    like($@, qr/\S/, "  with a reason");
};
$refused->({k => {image => 'i', programs => ['bash'], privileged => 1}}, 'privileged (not a setting of a pod)');
$refused->({k => {image => 'i', programs => ['bash'], devices => ['/etc/passwd']}}, 'a device outside /dev');
$refused->({k => {image => 'i', programs => ['bash'], devices => ['/dev/../etc/shadow']}}, 'a device with ..');
$refused->({k => {image => 'i', programs => ['bash'], usb_ids => ['zz:1']}}, 'a usb id that is not vid:pid hex');
$refused->({k => {image => 'i', programs => ['bash'], groups => ['dialout']}}, 'a group by name (a gid is a number)');
$refused->({k => {image => 'i', programs => ['bash'], env => {lower => 'x'}}}, 'an env name not in capitals');
$refused->({k => {image => 'i', programs => ['bash'], env => {X => "a\nb"}}}, 'an env value with a newline');
$refused->({k => {image => 'i', programs => ['bash'], seccomp => 'yes'}}, 'a seccomp that is not unconfined');
$refused->({k => {image => 'i', programs => ['bash'], ipc => 'private'}}, 'an ipc that is not host');

my $ok = eval {
    broker->new(%base, pods => {rocm => {image => 'i', programs => ['python3'], devices => ['/dev/kfd', '/dev/dri/card*'],
        groups => [44, 992], env => {ROCM_PATH => '/opt/rocm'}, seccomp => 'unconfined', ipc => 'host'}});
    1;
};
ok($ok, "a kind with its devices, groups, env, seccomp and ipc is accepted");

my $b = broker->new(%base, pods => {
    base => {image => 'img-bash', programs => [qw(bash perl grep)]},
    arduino => {image => 'img-ard', programs => ['arduino-cli'], devices => ['/dev/ttyACM*', '/dev/ttyUSB*'],
        usb_ids => ['0483:003A']},
    rocm => {image => 'img-rocm', programs => ['python3'], devices => ['/dev/kfd', '/dev/dri/card*'],
        groups => [44], env => {ROCM_PATH => '/opt/rocm'}, seccomp => 'unconfined', ipc => 'host'},
});
is($b->{pods}{arduino}{usb_ids}[0], '0483:003a', "usb ids are kept in lower case");
is_deeply($b->{pods}{rocm}{groups}, [44], "the groups of a kind");

# --- the devices at open -----------------------------------------------------------------

my ($devs, $gids) = $b->_device_specs($b->{pods}{arduino});
my @paths = map {$_->{path}} @$devs;
is_deeply([sort @paths], ['/dev/bus/usb/001/005', '/dev/ttyACM0'],
    "arduino: the board that is there, and the meter (its usb id, found in sysfs); ttyUSB0 is not there, so left out");
my ($ttya) = grep {$_->{path} eq '/dev/ttyACM0'} @$devs;
is($ttya->{type}, 'c', "a character device");
is($ttya->{major}, 1, "its major (the stand-in /dev/null has 1)");
is($ttya->{minor}, 3, "and its minor (3)");
my ($meter) = grep {$_->{path} =~ m{bus/usb}} @$devs;
is($meter->{major}, 1, "the usb node is a device of its own (the stand-in has its numbers)");

my $gid_null = (stat('/dev/null'))[5];
is_deeply($gids, $gid_null ? [$gid_null] : [], "the groups that own them: the owners' gids, root's left out");

($devs, $gids) = $b->_device_specs($b->{pods}{rocm});
is_deeply([map {$_->{path}} @$devs], ['/dev/kfd'], "rocm: kfd is there, the dri nodes are not (no dri in this /dev)");

($devs, $gids) = $b->_device_specs($b->{pods}{base});
is_deeply($devs, [], "a kind with no devices passes none");

# --- what the container spec gets ----------------------------------------------------------

my ($rdevs, $rgids) = $b->_device_specs($b->{pods}{rocm});
my $x = {devices => $rdevs, groups => [44, 992], env => {ROCM_PATH => '/opt/rocm'}, seccomp => 'unconfined', ipc => 'host'};
my $spec = $b->_container_spec('acme/alpha', 'aicli-rocm-alpha', 'img-rocm', $x);
is($spec->{devices}[0]{path}, '/dev/kfd', "the device of the spec");
is_deeply($spec->{groups}, ['44', '992'], "the groups, as strings");
is($spec->{env}{ROCM_PATH}, '/opt/rocm', "the variables");
is($spec->{seccomp_profile_path}, 'unconfined', "seccomp unconfined");
is_deeply($spec->{ipc}, {nsmode => 'host'}, "ipc of the host");
ok(!$spec->{privileged}, "still not privileged");
is_deeply($spec->{cap_drop}, ['ALL'], "still no capabilities");
ok($spec->{no_new_privileges}, "still no new privileges");
unlike($J->encode($spec), qr{"source":"/dev}, "no host device directory is mounted");

my $plain = $b->_container_spec('acme/alpha', 'aicli-base-acme-alpha', 'img-bash', {});
ok(!exists $plain->{devices} && !exists $plain->{groups} && !exists $plain->{env} && !exists $plain->{ipc},
    "a kind with nothing added gets a spec as before");

done_testing();
