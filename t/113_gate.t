#!/usr/bin/perl
# ui.pm: the agent accepts a request that nginx has checked (the shared secret AI_GATE_SECRET in
# X-Aicli-Gate), and keeps its own token for a request without nginx.
use strict; use warnings;

use Test::More;
use FindBin;

require "$FindBin::Bin/../ui.pm";

$ui::token = 'tok123';
$ui::gate = 's3cret-value';
ok(ui::_authed({ 'x-aicli-gate' => 's3cret-value' }), "the gate secret from nginx is accepted");
ok(!ui::_authed({ 'x-aicli-gate' => 'wrong' }), "another value is refused");
ok(!ui::_authed({}), "no secret and no token: refused");
ok(ui::_authed({ cookie => 'aicli_token=tok123' }), "the token of the page still works without nginx");
ok(!ui::_authed({ cookie => 'aicli_token=nope' }), "a wrong token is refused");

$ui::gate = undef;
ok(!ui::_authed({ 'x-aicli-gate' => 's3cret-value' }), "without AI_GATE_SECRET the header means nothing");

done_testing();
