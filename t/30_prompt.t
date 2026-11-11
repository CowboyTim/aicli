#!/usr/bin/perl
use strict; use warnings;

use Test::More;
use Data::Dumper;
use FindBin;
use lib "$FindBin::Bin/..";
local $Data::Dumper::Sortkeys = 1;
no warnings 'once';

$::DEBUG = ($ENV{DEBUG}//"0") == "1"?1:0;

use_ok("ai");

# the tools section that the "coder" template adds to the system prompt
{
    my $p = prompt::coder::prompt();
    like($p, qr/\A\n\n\*\*TOOLS\*\*\n/, "starts with the TOOLS header");
    like($p, qr/To call a tool, write its block exactly/, "says how to call a tool");
    like($p, qr{^///TOOL_\{HEX\}\+\{T1\}\+\{T2\}\n\{\{path\}\}\n\{T1\}\[<size of substituted \{\{path\}\}>\]\n\{\{content\}\}\n\{T2\}\[<size of substituted \{\{content\}\}>\]\nTOOL_\{HEX\}\n}m, "generic syntax");
    like($p, qr/^TOOL results: \[<TOOL_\{HEX\}> RESULT_d170\n\{\{result\}\}\nRESULT_d170\]$/m, "result format");
    like($p, qr/^TOOL errors: \[<TOOL_\{HEX\}> ERROR_9a78\n\{\{error\}\}\nERROR_9a78\]$/m, "error format");

    # every tool: name, syntax, description, properties - sorted by name
    my @names = $p =~ m/^name: (\w+)$/mg;
    is_deeply(\@names, [sort keys %$tools::TOOLS], "all tools listed, sorted");
    foreach my $name (sort keys %$tools::TOOLS){
        my $t = $tools::TOOLS->{$name};
        like($p, qr/^name: $name\ntool: ```\n\Q$t->{syntax}\E\n```\ndescription: \Q$t->{description}\E\nproperties:\n/m, "$name: syntax and description");
        like($p, qr/^ $_:\n  description: \Q$t->{properties}{$_}{description}\E\n  type: string\n/m, "$name: property $_")
            for sort keys %{$t->{properties}};
        like($p, qr/^example: ```\n\Q$t->{example}\E```\n/m, "$name: example")
            if $t->{example};
    }

    # what the prompt shows must be what the parser accepts
    foreach my $name (grep {$tools::TOOLS->{$_}{example}} sort keys %$tools::TOOLS){
        my $called;
        no warnings 'redefine';
        no strict 'refs';
        local *{"tools::".lc($tools::TOOLS->{$name}{tag})} = sub {$called = $_[0]; "ok"};
        my ($n) = ai::handle_llm_response(\$tools::TOOLS->{$name}{example}, sub {});
        is($n, 1, "$name: the example is a valid tool call");
        is(scalar(@{$called // []}), scalar(@{$tools::TOOLS->{$name}{required}}), "$name: example has all arguments");
    }
    is(UNIVERSAL::can("prompt::default", "prompt"), undef, "the default template has no tools section");
}

done_testing();
