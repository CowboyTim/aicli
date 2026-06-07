package utils;

use strict; use warnings;

sub load_cpan {
    my ($module) = @_;
    eval "require $module";
    die $@ if $@;
    return $module;
}

our $curl_handle;
our $response = \(my $buffer = ""); 
sub http {
    my ($m, $full_url, $data, $api_key) = @_;
    $data //= "";
    log::info("URL: $full_url");
    log::info("DATA: $data");
    $$response = "";
    $curl_handle //= do {
        my $ch = curl->new();
        $ch->setopt(curl::CURLOPT_IPRESOLVE(), curl::CURL_IPRESOLVE_V6());
        $ch->setopt(curl::CURLOPT_WRITEFUNCTION(), sub {
            my ($ch, $chunk) = @_;
            $$response .= $chunk;
            return length($chunk);
        });
        $ch->setopt(curl::CURLOPT_VERBOSE(), $::DEBUG?1:0);
        $ch->setopt(curl::CURLOPT_HTTPHEADER(), [
            "Accept: application/json",
            "Content-Type: application/json",
            "User-Agent: AI Chat/0.1",
            "Connection: Keep-Alive",
            "Keep-Alive: max=100",
            ($api_key ?(
                "Authorization: Bearer $api_key",
            ):()),
        ]);
        if(my $proxy = $::ORIG_ENV{AI_PROXY} // $::ORIG_ENV{HTTPS_PROXY} // $::ORIG_ENV{HTTP_PROXY}){
            $ch->setopt(curl::CURLOPT_PROXY(), $proxy);
        }
        $ch;
    };
    $curl_handle->setopt(curl::CURLOPT_URL(), $full_url);
    if(lc($m) eq "post"){
        $curl_handle->setopt(curl::CURLOPT_POST(), 1);
        if(length($data)){
            $curl_handle->setopt(curl::CURLOPT_POSTFIELDS(), $data);
            $curl_handle->setopt(curl::CURLOPT_POSTFIELDSIZE_LARGE(), length($data));
        }
    }
    if(lc($m) eq "get"){
        $curl_handle->setopt(curl::CURLOPT_HTTPGET(), 1);
    }
    $curl_handle->perform();
    my $r_code = $curl_handle->getinfo(curl::CURLINFO_HTTP_CODE());
    if($r_code != 200){
        log::info("ERROR: $r_code");
        return;
    }
    log::info("OK: $r_code");
    log::info("RESPONSE:\n$$response");
    return $$response;
}

package curl;

use strict; use warnings;

BEGIN {
    die $@ if $@;
    eval {utils::load_cpan("Net::Curl")};
    eval {utils::load_cpan("Net::Curl::Easy")};
    our @ISA = qw(Net::Curl::Easy);
    foreach my $k (keys %Net::Curl::Easy::){
        next unless $k =~ /^CURL/; # Only grab curl constants/options
        no strict 'refs';
        *{"${k}"} = \&{"Net::Curl::Easy::${k}"};
    }
}

package log;

use strict; use warnings;

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
