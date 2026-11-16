#!/usr/bin/perl
# the image gets every program file of the repository: each module in the root
# is in the COPY lines of the Dockerfile (a missing one only shows at run time)
use strict; use warnings;

use Test::More;
use FindBin;

my $ROOT = "$FindBin::Bin/..";
opendir(my $dh, $ROOT) or die "opendir: $!";
my @pm = sort grep {/\.pm\z/} readdir($dh);
closedir($dh);

open(my $fh, '<', "$ROOT/Dockerfile") or die "Dockerfile: $!";
my @copy = grep {/^COPY\s/} <$fh>;
close($fh);
my %in = map {$_ => 0} @pm;
for my $line (@copy) {
    for my $f (@pm) {
        $in{$f}++ if $line =~ m/(?<![\w.])\Q$f\E(?![\w.])/;
    }
}

ok(@pm, "there are modules in the root");
for my $f (@pm) {
    ok($in{$f}, "$f is copied into the image (in every stage that has the program)");
}

done_testing();
