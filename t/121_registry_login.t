#!/usr/bin/perl
# the pod registries of the broker: the registries of the config (and what is refused), the
# images that must come from them, the login sent with a pull (X-Registry-Auth) to that
# registry only, and what happens when its variables are not set. The engine is a stub here.
use strict; use warnings;

use Test::More;
use FindBin;
use MIME::Base64 ();
use JSON::XS ();

require "$FindBin::Bin/../broker.pl";
no warnings 'once';

my $J = JSON::XS->new->canonical(1)->utf8;
my %pods = (bash => {image => 'reg.example/aicli/pod-bash:latest', programs => ['bash']});
my %regs = ('reg.example' => {username_env => 'T_USER', password_env => 'T_PASS'});

# --- the registries of the config -------------------------------------------------------

my $ok = eval { broker::_registries_config({registries => {'BAD HOST' => {username_env => 'A', password_env => 'B'}}}); 1 };
ok(!$ok, "a registry that is not a host name is refused");
$ok = eval { broker::_registries_config({registries => {'reg.example' => {username_env => 'user', password_env => 'B'}}}); 1 };
ok(!$ok, "a variable name that is not in capitals is refused");
$ok = eval { broker::_registries_config({registries => {'reg.example' => {username_env => 'A'}}}); 1 };
ok(!$ok, "a registry without its password variable is refused");
is_deeply(broker::_registries_config({registries => \%regs}), \%regs, "a good list comes back as it is");
is_deeply(broker::_registries_config({}), {}, "no registries: none");

# --- which registry an image is from -----------------------------------------------------

is(broker::_registry_of('reg.example/aicli/pod-bash:latest'), 'reg.example', "a host in front: that registry");
is(broker::_registry_of('localhost:5000/x:1'), 'localhost:5000', "a host with a port");
is(broker::_registry_of('ubuntu:24.04'), 'docker.io', "no host: docker.io");
is(broker::_registry_of('library/ubuntu'), 'docker.io', "a path without a host: docker.io");

# --- the images must come from the registries of the config ------------------------------

my $b = broker->new(root => '/tmp', host_root => '/tmp', engine => '/nonexistent', registries => \%regs, pods => \%pods);
is($b->{pods}{bash}{image}, 'reg.example/aicli/pod-bash:latest', "an image of a listed registry is accepted");
$ok = eval { broker->new(root => '/tmp', host_root => '/tmp', engine => '/nonexistent', registries => \%regs,
    pods => {bash => {image => 'other.example/x:1', programs => ['bash']}}); 1 };
ok(!$ok, "an image from a registry that is not listed is refused");
like($@, qr/other\.example, which is not a registry of the config/, "and says which");
$ok = eval { broker->new(root => '/tmp', host_root => '/tmp', engine => '/nonexistent', registries => \%regs,
    pods => {bash => {image => 'ubuntu:24.04', programs => ['bash']}}); 1 };
ok(!$ok, "an image from docker.io is refused when only other registries are listed");
my $plain = broker->new(root => '/tmp', host_root => '/tmp', engine => '/nonexistent',
    pods => {bash => {image => 'ubuntu:24.04', programs => ['bash']}});
is($plain->{pods}{bash}{image}, 'ubuntu:24.04', "with no registries in the config, any image is as before");

# --- the login -----------------------------------------------------------------------------

{
    local $ENV{T_USER} = 'pusher';
    local $ENV{T_PASS} = 'pa:ss word';
    my ($auth, $why) = $b->_auth_header('reg.example/aicli/pod-bash:latest');
    is($why, undef, "with its variables set: no reason to refuse");
    my $login = $J->decode(MIME::Base64::decode_base64($auth));
    is_deeply($login, {username => 'pusher', password => 'pa:ss word', serveraddress => 'reg.example'},
        "the login of that registry, as the engine takes it");
    my ($none, $none_why) = $b->_auth_header('other.example/x:1');
    ok(!defined $none && !defined $none_why, "no login is sent to a registry that is not in the config");
    ($none, $none_why) = $plain->_auth_header('ubuntu:24.04');
    ok(!defined $none && !defined $none_why, "and none for docker.io when nothing is configured");
}
{
    local $ENV{T_USER};
    delete $ENV{T_USER};
    local $ENV{T_PASS} = 'x';
    my ($auth, $why) = $b->_auth_header('reg.example/aicli/pod-bash:latest');
    ok(!defined $auth && defined $why, "a variable that is not set: no login, and the reason");
    like($why, qr/T_USER/, "the reason names the variable, not its value");
}

# --- the pull sends the login, to that registry --------------------------------------------

my @calls;
{
    no warnings 'redefine';
    local *broker::_engine = sub {
        my ($self, $method, $path, $data, $headers) = @_;
        push @calls, {method => $method, path => $path, headers => $headers};
        return (404, '{}') if $method eq 'GET';           # not there yet: pull it
        return (200, '{}');                                # the pull is done
    };
    local $ENV{T_USER} = 'pusher';
    local $ENV{T_PASS} = 'secret';
    my $r = $b->_image('reg.example/aicli/pod-bash:latest');
    ok(!$r, "a missing image is pulled, and that works");
    my ($pull) = grep {$_->{method} eq 'POST'} @calls;
    my ($h) = grep {$_->[0] eq 'X-Registry-Auth'} @{ $pull->{headers} // [] };
    ok($h, "the pull sends X-Registry-Auth");
    is($J->decode(MIME::Base64::decode_base64($h->[1]))->{username}, 'pusher', "with the login of its registry");

    @calls = ();
    $b->_image('ubuntu:24.04');
    my ($pull2) = grep {$_->{method} eq 'POST'} @calls;
    is(scalar(@{ $pull2->{headers} // [] }), 0, "a pull from a registry without a login sends no header");
}

done_testing();
