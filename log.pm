package log;

use strict; use warnings;

sub load_cpan {
    my ($module) = @_;
    eval "require $module";
    die $@ if $@;
    return $module;
}

sub info {
    my ($message) = @_;
    return unless $::DEBUG;
    my $LOG_FILE = $::ORIG_ENV{AI_LOG} // "&STDOUT";
    my $lfh;
    open($lfh, ">>$LOG_FILE") or open($lfh, ">&STDERR") or return;
    print {$lfh} "INFO: [$$]: ".scalar(localtime()).": $message\n";
    close $lfh or die "Failed to close dup/file $LOG_FILE: $!\n";
    return;
}

sub error {
    my ($message) = @_;
    my $LOG_FILE = $::ORIG_ENV{AI_LOG} // "&STDOUT";
    my $lfh;
    open($lfh, ">>$LOG_FILE") or open($lfh, ">&STDERR") or return;
    print {$lfh} "ERROR: [$$]: ".scalar(localtime()).": $message\n";
    close $lfh or die "Failed to close dup/file $LOG_FILE: $!\n";
    return;
}


1;
