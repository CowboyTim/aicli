package ai;

use strict; use warnings;

use utils;
use tui;

use Cwd ();
use Encode ();
use Errno;
use JSON::XS ();
use Time::HiRes ();

BEGIN {
    $::JSON //= JSON::XS->new->utf8->allow_blessed->allow_unknown->allow_nonref->convert_blessed;
}

# Variables/Handles
our ($api_key, $AI_ENDPOINT_URL, $SESSION_MODEL, $provider_name);
our ($AI_SESSION_DIR, $HISTORY_FILE, $PROMPT_FILE, $STATUS_FILE, $BASE_DIR, $AI_PROMPT_TEMPLATE, $AI_PROMPT_TEMPLATE_FILE, $AI_SESSION, $SESSIONS_DIR, $AI_PROVIDER, $AI_URL);
our $cmds;
our @MODELS;
our $TUI = tui->new(enabled => 0); # the status line, switched on in chat_loop
our $BUSY = 0;      # a completion/tool turn is running: ctrl-C aborts the turn only
our $MAIN_PID = $$;

our %PROVIDERS = (
    'cerebras' => {
        url => 'https://api.cerebras.ai',
        key_prefix => 'csk-',
    },
    'openrouter' => {
        url => 'https://openrouter.ai/api',
        key_prefix => 'sk-or-',
    },
    'nvidia' => {
        url => 'https://integrate.api.nvidia.com',
        key_prefix => 'nvapi-',
    },
    'lemonade' => {
        url   => 'http://localhost:8000',
        local => 1, # no API key needed
    },
);

# tool processes never get to see the API key
push @utils::CHILD_INIT, sub {$api_key = undef};

sub chat_setup {
    my ($base_dir) = @_;
    if($::ORIG_ENV{CDIR}){
        chdir($::ORIG_ENV{CDIR})
            or die "Error chdir to CDIR=$::ORIG_ENV{CDIR}: $!\n";
    }

    $BASE_DIR = $base_dir;
    my $cfg_file = $::ORIG_ENV{AI_CONFIG}
        // "$BASE_DIR/config";
    log::info("open config $cfg_file");
    if (-f $cfg_file) {
        open(my $fh, ". $cfg_file; set|")
            or die "Failed to read $cfg_file: $!\n";
        my %envs = map {chomp; split m/=/, $_, 2} grep m/^AI_/, <$fh>;
        while (my ($key, $value) = each %envs) {
            $::ORIG_ENV{$key} //= $value =~ s/^['"]//r =~ s/['"]$//r;
        }
        close $fh;
    }

    $SESSIONS_DIR = "$BASE_DIR/sessions";
    -d $SESSIONS_DIR
        or mkdir $SESSIONS_DIR
        or die "Failed to create $SESSIONS_DIR: $!\n";

    $AI_PROMPT_TEMPLATE = $::ORIG_ENV{AI_PROMPT_TEMPLATE}
        // 'default';
    $AI_PROMPT_TEMPLATE_FILE = $::ORIG_ENV{AI_PROMPT_TEMPLATE_FILE}
        // "$FindBin::Bin/ai/$AI_PROMPT_TEMPLATE";
    $AI_SESSION = $::ORIG_ENV{AI_SESSION}
        // $::ORIG_ENV{AI_PROMPT_DEFAULT};
    $AI_SESSION = "session-".new_session_id()
        unless length($AI_SESSION // '');
    if(!valid_session_name($AI_SESSION)){
        log::error("Invalid session name '$AI_SESSION' (use letters, digits, '.', '_' and '-')");
        exit 1;
    }
    $provider_name = lc($::ORIG_ENV{AI_PROVIDER} // '');
    $api_key = $::ORIG_ENV{AI_API_KEY};

    if ($::ORIG_ENV{AI_LOCAL_SERVER}) {
        # any OpenAI compatible server, e.g. llama.cpp or lemonade
        $AI_ENDPOINT_URL = $::ORIG_ENV{AI_LOCAL_SERVER};
        $AI_PROVIDER = $provider_name || 'local';
    } else {
        # Detect provider by key prefix
        my $detected_provider;
        if (length($api_key // '')) {
            for my $name (sort keys %PROVIDERS) {
                next unless $PROVIDERS{$name}{key_prefix};
                if (index($api_key, $PROVIDERS{$name}{key_prefix}) == 0) {
                    $detected_provider = $name;
                    last;
                }
            }
        }

        # The configured provider wins, else what the key tells
        if ($provider_name and exists $PROVIDERS{$provider_name}) {
            $AI_PROVIDER = $provider_name;
        } elsif ($detected_provider) {
            $AI_PROVIDER = $detected_provider;
        } elsif (!length($api_key // '')) {
            log::error("Please set AI_API_KEY environment variable or set $BASE_DIR/config");
            exit 1;
        } else {
            log::error("Unable to detect provider from API key. Set AI_PROVIDER environment variable");
            log::error("Supported providers: ".join(', ', sort keys %PROVIDERS).", or set AI_LOCAL_SERVER");
            exit 1;
        }
        if (!length($api_key // '') and !$PROVIDERS{$AI_PROVIDER}{local}) {
            log::error("Please set AI_API_KEY environment variable or set $BASE_DIR/config");
            exit 1;
        }
        $AI_ENDPOINT_URL = $PROVIDERS{$AI_PROVIDER}{url};
    }

    # Normalize URL: no trailing / and no /v1, that is added per endpoint
    $AI_ENDPOINT_URL =~ s|/+$||;
    $AI_ENDPOINT_URL =~ s|/v1$||;

    # AI_RAW point for e.g. non-jinja
    $AI_URL = "$AI_ENDPOINT_URL/v1/chat/completions";
    $AI_URL = "$AI_ENDPOINT_URL/v1/completions" if $::ORIG_ENV{AI_RAW};

    init_session($AI_SESSION);
    use_session($AI_SESSION);
    return;
}

sub new_session_id {
    my $id = eval {
        utils::load_cpan("Data::UUID");
        Data::UUID->new()->create_str();
    };
    return $id if $id;
    # no Data::UUID: time + pid + random is unique enough for a directory name
    return sprintf("%08X-%04X-%04X-%04X-%06X%06X", time(), $$ & 0xffff,
        map {int(rand($_))} 0x10000, 0x10000, 0x1000000, 0x1000000);
}

sub valid_session_name {
    my ($name) = @_;
    return 0 unless defined $name;
    return 0 unless $name =~ m/^[A-Za-z0-9_][A-Za-z0-9_.\-]*$/;
    return 1;
}

# point all per-session globals to a session
sub use_session {
    my ($session) = @_;
    $AI_SESSION     = $session;
    $AI_SESSION_DIR = "$SESSIONS_DIR/$AI_SESSION";
    $HISTORY_FILE   = "$AI_SESSION_DIR/history";
    $PROMPT_FILE    = "$AI_SESSION_DIR/prompt";
    $STATUS_FILE    = "$AI_SESSION_DIR/chat";
    $SESSION_MODEL  = read_session_model() || $::ORIG_ENV{AI_MODEL};
    return;
}

sub clean_model_name {
    my ($m) = @_;
    $m //= '';
    $m =~ s/^\s+//;
    $m =~ s/\s+$//;
    $m =~ s/^['"]//;
    $m =~ s/['"]$//;
    return $m;
}

sub read_session_model {
    open(my $mfh, '<', "$AI_SESSION_DIR/model")
        or return '';
    my $m = <$mfh>;
    close $mfh;
    return clean_model_name($m);
}

sub slurp {
    my ($file) = @_;
    open(my $fh, '<', $file)
        or return;
    local $/;
    my $data = <$fh>;
    close($fh);
    return $data // '';
}

sub spew {
    my ($file, $data) = @_;
    my $tmp = "$file.tmp";
    open(my $fh, '>', $tmp)
        or die "Failed to write to $tmp: $!\n";
    print {$fh} $data;
    close($fh)
        or die "Failed to close $tmp: $!\n";
    rename($tmp, $file)
        or die "Failed to rename $tmp to $file: $!\n";
    return;
}

# raw bytes (terminal, files, tool output) -> text, as JSON wants it
sub to_text {
    my ($s) = @_;
    $s //= '';
    utf8::decode($s) unless utf8::is_utf8($s);
    return $s;
}

# text -> bytes for the terminal, files and tools
sub to_bytes {
    my ($s) = @_;
    $s //= '';
    utf8::encode($s) if utf8::is_utf8($s);
    return $s;
}

#------------------------------------------------------------------------------
# chat state: one JSON message per line in the session "chat" file

sub load_messages {
    my ($file) = @_;
    $file //= $STATUS_FILE;
    open(my $fh, '<', $file)
        or die "Failed to read $file: $!\n";
    my @msgs = map {JSON::XS::decode_json($_)} grep {m/\S/} <$fh>;
    close $fh;
    return @msgs;
}

sub append_messages {
    my (@msgs) = @_;
    return unless @msgs;
    open(my $fh, '>>', $STATUS_FILE)
        or die "Failed to write to $STATUS_FILE: $!\n";
    print {$fh} $::JSON->encode($_)."\n" for @msgs;
    close $fh
        or die "Failed to close $STATUS_FILE: $!\n";
    return;
}

sub write_messages {
    my (@msgs) = @_;
    spew($STATUS_FILE, join('', map {$::JSON->encode($_)."\n"} @msgs));
    return;
}

#------------------------------------------------------------------------------
# LLM response handling: find the tool calls, run them, return the results

sub strip_thinking {
    my ($msg) = @_;
    $msg //= '';
    $msg =~ s/<think>.*?<\/think>[ \t]*\n?//sg;
    return $msg;
}

# Parse one tool call at pos($$msg_r), which is just after the "///TOOL_hex"
# header line. The arguments are each closed by their own sentinel line, the
# sentinels come from the header, or from the tool definition when the model
# messed up the header.
sub parse_tool_args {
    my ($msg_r, $t, $declared) = @_;
    my @canonical = @{$t->{sentinels}};
    my @declared  = grep {length} split m/\+/, $declared // '';
    my $start = pos($$msg_r);
    SENTINELS:
    foreach my $sentinels (@declared == @canonical ? (\@declared, \@canonical) : (\@canonical)){
        pos($$msg_r) = $start;
        my @t_args;
        foreach my $s (@$sentinels){
            $$msg_r =~ m/\G(.*?)^\Q$s\E(?:\[\d*\])?[ \t]*(?:\n|\z)/msgc
                or next SENTINELS;
            my $arg = $1;
            $arg =~ s/\n\z//;
            push @t_args, $arg;
        }
        # the closing tag is nice to have
        $$msg_r =~ m/\G\s*\Q$t->{tag}\E[ \t]*(?:\n|\z)/gc;
        return \@t_args;
    }
    pos($$msg_r) = $start;
    return;
}

# the tool calls in an answer (bytes): a list of {tool, k, t, args}, where
# args is undef for a call that could not be parsed
sub parse_tool_calls {
    my ($msg) = @_;
    my @calls;
    my $t_rx = tools::rx();
    while($msg =~ m/$t_rx/mg){
        my ($tool, $declared) = ($1, $2);
        my $tool_k = lc($tool =~ s/_[0-9a-fA-F]+$//r);
        my $t = $tools::TOOLS->{$tool_k}
            or next;
        my $t_args = parse_tool_args(\$msg, $t, $declared);
        log::info("TOOL:$tool, K:$tool_k, A:".join(' ', @{$t_args // ['<malformed>']}));
        push @calls, {tool => $tool, k => $tool_k, t => $t, args => $t_args};
    }
    return @calls;
}

sub malformed_error {
    my ($c) = @_;
    return "[ERROR] malformed tool call for '$c->{tool}', nothing was executed. Expected syntax:\n$c->{t}{syntax}";
}

# what the model gets to see of a tool run
sub tool_response {
    my ($tool, $result, $had_error) = @_;
    return "[$tool ERROR_9a78\n$had_error\nERROR_9a78]" if $had_error;
    return "[$tool RESULT_d170\n".($result // '')."\nRESULT_d170]";
}

sub handle_llm_response {
    my ($resp, $printer_sub) = @_;
    return (0, 0, []) unless defined $resp and ref($resp) eq 'SCALAR' and length($$resp // "");
    log::info("handling>>$$resp<<");
    $printer_sub //= sub {
        my ($r) = @_;
        $TUI->clear();
        print $r;
    };

    # tools work with bytes, and never run from within a thinking block
    my $msg = to_bytes(strip_thinking($$resp));
    log::info("MSG THINK STRIPPED>>$msg<<");
    my (@rt, @agents);
    my $answer = sub {
        my ($i, $c, $result, $had_error) = @_;
        my $tool_response = tool_response($c->{tool}, $result, $had_error);
        &{$printer_sub}("${colors::green_color}$tool_response${colors::reset_color}\n");
        $rt[$i] = {role => 'user', content => to_text($tool_response)};
    };
    foreach my $c (parse_tool_calls($msg)){
        my $i = scalar(@rt);
        push @rt, undef;
        &{$printer_sub}("${colors::yellow_color1}\[TOOL $c->{tool}\(...))\]${colors::reset_color}\n");
        if(utils::aborted()){
            &{$answer}($i, $c, "", "[ERROR] not executed, interrupted by user");
        } elsif(!$c->{args}){
            &{$answer}($i, $c, "", malformed_error($c));
        } elsif($c->{k} eq 'agent'){
            # sub-agents are started now and work side by side, their answers
            # are collected below
            push @agents, [$i, $c, agent::launch($c->{args}[0])];
        } else {
            $TUI->set('tool', $c->{k});
            my @r = execute_tool($c->{k}, $c->{tool}, $c->{args});
            $TUI->unset('tool');
            &{$answer}($i, $c, @r);
        }
    }
    if(@agents){
        agent::wait(map {$_->[2]} @agents);
        foreach my $e (@agents){
            my ($i, $c, $a) = @$e;
            &{$answer}($i, $c, agent_result($a));
        }
    }

    my $newturns = @rt ? 1 : 0;
    return $newturns, ($newturns ? undef : 0), \@rt;
}

# ($result, $error) of a finished sub-agent, as for a tool
sub agent_result {
    my ($a) = @_;
    return (truncate_output($a->{result} // ''), undef) unless defined $a->{error};
    return ("", truncate_output("[ERROR] agent $a->{id} failed: $a->{error}"
        .(length($a->{result} // '') ? "\nIts last answer was:\n$a->{result}" : "")));
}

# Run a tool without waiting for it: $cb is called with ($result, $error), at
# once for the tools that run in this process, from the event loop for the
# ones that fork. For the sub-agents.
sub execute_tool_async {
    my ($k, $tool, $t_args, $cb) = @_;
    my $t  = $tools::TOOLS->{$k};
    my $fn = $t && tools->can(lc $t->{tag});
    return &{$cb}("", "[ERROR] Unknown tool '$tool'") unless $fn;
    return &{$cb}("", "[ERROR] a sub-agent cannot start agents") if $k eq 'agent';
    my $ret = eval {
        local $tools::ASYNC = 1; # forking tools hand back a job instead of waiting
        &{$fn}($t_args);
    };
    if($@){
        chomp(my $err = $@);
        return &{$cb}("", truncate_output("[ERROR] problem running tool '$tool': $err"));
    }
    return &{$cb}(truncate_output($ret // ""), undef) unless ref($ret) eq 'tools::job';
    loop::spawn($ret->{worker}, timeout => $ret->{timeout}, on_done => sub {
        my $out = eval {&{$ret->{finish}}(@_)};
        if($@){
            chomp(my $err = $@);
            return &{$cb}("", truncate_output("[ERROR] problem running tool '$tool': $err"));
        }
        return &{$cb}(truncate_output($out // ""), undef);
    });
    return;
}

sub execute_tool {
    my ($k, $tool, $t_args) = @_;
    my $t  = $tools::TOOLS->{$k};
    my $fn = $t && tools->can(lc $t->{tag});
    return "", "[ERROR] Unknown tool '$tool'" unless $fn;
    my $ret = eval {&{$fn}($t_args)};
    if($@){
        chomp(my $err = $@);
        return "", truncate_output("[ERROR] problem running tool '$tool': $err");
    }
    return truncate_output($ret // ""), undef;
}

# keep the context window alive: cut the middle out of huge tool outputs
sub truncate_output {
    my ($out) = @_;
    my $max = $::ORIG_ENV{AI_TOOL_MAX_OUTPUT} // 65536;
    return $out if !$max or length($out) <= $max;
    my $half = int($max / 2);
    my $cut  = length($out) - 2 * $half;
    return substr($out, 0, $half)."\n[... $cut bytes truncated ...]\n".substr($out, -$half);
}

#------------------------------------------------------------------------------
# streaming: SSE parsing, thinking/answer separation

# Returns a stream state: feed it raw HTTP chunks with $st->{feed}->($raw), it
# calls $emit->($kind, $text) with $kind 'think' or 'text' for whatever needs
# showing, and collects the answer in $st->{content}.
sub new_stream {
    my ($emit) = @_;
    my $st = {
        rbuf      => '', # unparsed raw bytes
        content   => '', # the assistant answer, <think> blocks included
        reasoning => '', # reasoning sent out-of-band by the API
        pending   => '', # possible start of a <think> tag, not shown yet
        in_think  => 0,
        done      => 0,
        events    => 0,
        error     => undef,
        usage     => undef,
    };
    my $content = sub {
        my ($delta) = @_;
        $st->{content} .= $delta;
        $st->{pending} .= $delta;
        while(length($st->{pending})){
            my $tag = $st->{in_think} ? '</think>' : '<think>';
            my $i = index($st->{pending}, $tag);
            if($i >= 0){
                &{$emit}($st->{in_think} ? 'think' : 'text', substr($st->{pending}, 0, $i));
                substr($st->{pending}, 0, $i + length($tag)) = '';
                $st->{in_think} = !$st->{in_think};
                next;
            }
            # a tag can be split over deltas: hold back what may be its start
            my $hold = 0;
            for my $l (reverse 1 .. length($tag) - 1){
                next if $l > length($st->{pending});
                if(substr($st->{pending}, -$l) eq substr($tag, 0, $l)){
                    $hold = $l;
                    last;
                }
            }
            my $show = substr($st->{pending}, 0, length($st->{pending}) - $hold);
            &{$emit}($st->{in_think} ? 'think' : 'text', $show);
            $st->{pending} = $hold ? substr($st->{pending}, -$hold) : '';
            last;
        }
    };
    $st->{event} = sub {
        my ($decoded) = @_;
        return unless ref($decoded) eq 'HASH';
        $st->{events}++;
        $st->{usage} = $decoded->{usage} if ref($decoded->{usage}) eq 'HASH';
        if(my $e = $decoded->{error}){
            $st->{error} = $decoded;
            return;
        }
        my $msg_entry = ref($decoded->{choices}) eq 'ARRAY' ? ($decoded->{choices}[0] // {}) : {};
        my $d = $msg_entry->{delta} // $msg_entry->{message} // {};
        my $reasoning = $d->{reasoning_content} // $d->{reasoning};
        if(defined $reasoning and !ref($reasoning) and length($reasoning)){
            $st->{reasoning} .= $reasoning;
            &{$emit}('think', $reasoning);
        }
        my $delta = $d->{content} // $msg_entry->{text};
        if(defined $delta and !ref($delta) and length($delta)){
            &{$content}($delta);
        }
    };
    $st->{feed} = sub {
        my ($raw) = @_;
        $st->{rbuf} .= $raw;
        $st->{rbuf} =~ s/\r\n/\n/g;
        # Server-Sent Events: blocks separated by an empty line
        while($st->{rbuf} =~ s/\A(.*?)\n\n//s){
            my $data = join("\n", map {m/^data:[ \t]?(.*)$/ ? $1 : ()} split m/\n/, $1);
            next unless length($data);
            if($data =~ m/^\[DONE\]\s*$/){
                $st->{done} = 1;
                next;
            }
            my $decoded = eval {JSON::XS->new->utf8->decode($data)};
            if($@){
                log::info("Failed to decode SSE event: $data, error: $@");
                next;
            }
            &{$st->{event}}($decoded);
        }
    };
    $st->{finish} = sub {
        # what is left is a non streamed (error) reply, or nothing
        if($st->{rbuf} =~ m/\S/){
            my $decoded = eval {JSON::XS->new->utf8->decode($st->{rbuf})};
            if(ref($decoded) eq 'HASH'){
                $st->{rbuf} = '';
                &{$st->{event}}($decoded);
            }
        }
        if(length($st->{pending})){
            &{$emit}($st->{in_think} ? 'think' : 'text', $st->{pending});
            $st->{pending} = '';
        }
    };
    return $st;
}

# Shows thinking and answer in their own color while they stream in
sub new_printer {
    my ($out) = @_;
    $out //= sub {$TUI->clear(); print $_[0]};
    my $show_thinking = ($::ORIG_ENV{AI_SHOW_THINKING} // 1) ? 1 : 0;
    my ($last, $ends_nl) = ('', 1);
    my $p = {};
    $p->{emit} = sub {
        my ($kind, $text) = @_;
        return unless length($text // '');
        return if $kind eq 'think' and !$show_thinking;
        if($last ne $kind){
            # thinking and answer each start on a line of their own, without
            # the empty lines models put in between
            $text =~ s/\A\n+//;
            return unless length($text);
            &{$out}("\n") unless $ends_nl;
        }
        my $color = $kind eq 'think' ? $colors::yellow_color1 : $colors::green_color;
        &{$out}($color.to_bytes($text).$colors::reset_color);
        $last    = $kind;
        $ends_nl = $text =~ m/\n\z/ ? 1 : 0;
    };
    $p->{finish} = sub {
        &{$out}("\n") unless $ends_nl;
        ($last, $ends_nl) = ('', 1);
    };
    return $p;
}

sub format_api_error {
    my ($decoded, $fallback) = @_;
    my $emsg = "ERROR: ";
    my $e = ref($decoded) eq 'HASH' ? $decoded->{error} : undef;
    if(ref($e) eq 'HASH'){
        $emsg .= join(": ", grep {defined and length} $e->{code}, $e->{message} // $e->{type});
        if(ref($e->{metadata}) eq 'HASH' and ref($e->{metadata}{headers}) eq 'HASH'){
            my $h = $e->{metadata}{headers};
            $emsg .= ", limit: $h->{'X-RateLimit-Limit'}"
                if defined $h->{'X-RateLimit-Limit'};
            $emsg .= ", remaining: $h->{'X-RateLimit-Remaining'}"
                if defined $h->{'X-RateLimit-Remaining'};
            $emsg .= ", reset: ".POSIX::strftime("%F %T", gmtime(($h->{'X-RateLimit-Reset'} // 0) =~ s/^(.*)?...$/$1/gr))
                if defined $h->{'X-RateLimit-Reset'};
        }
    } elsif(defined $e and length($e)){
        $emsg .= ref($e) ? $::JSON->encode($e) : $e;
    } else {
        $emsg .= $fallback // "unknown error";
    }
    return $emsg;
}

# durations of rate limit headers: seconds ("12", "0.5"), go style ("6m0s",
# "250ms"), or a point in time (epoch seconds or milliseconds)
sub parse_duration {
    my ($v) = @_;
    return unless defined $v and length($v);
    if($v =~ m/^\d+(?:\.\d+)?$/){
        return $v / 1000 - time() if $v > 1e11; # epoch ms
        return $v - time()        if $v > 1e9;  # epoch s
        return $v + 0;
    }
    return unless $v =~ m/^(?:[\d.]+(?:ms|h|m|s))+$/;
    my %f = (h => 3600, m => 60, s => 1, ms => 0.001);
    my $d = 0;
    $d += $1 * $f{$2} while $v =~ m/([\d.]+)(ms|h|m|s)/g;
    return $d;
}

# how long the API wants us to wait after a rate limit, undef if it didn't say
sub rate_limit_wait {
    my ($headers, $decoded) = @_;
    my $h = {%{$headers // {}}};
    my $e = ref($decoded) eq 'HASH' ? $decoded->{error} : undef;
    if(ref($e) eq 'HASH' and ref($e->{metadata}) eq 'HASH' and ref($e->{metadata}{headers}) eq 'HASH'){
        $h->{lc $_} //= $e->{metadata}{headers}{$_} for keys %{$e->{metadata}{headers}};
    }
    my $ms = parse_duration($h->{'retry-after-ms'});
    return $ms / 1000 if defined $ms;
    my $ra = parse_duration($h->{'retry-after'});
    return $ra if defined $ra;
    my @w = sort {$a <=> $b} grep {defined and $_ > 0} map {parse_duration($h->{$_})} grep {m/^x-ratelimit-reset/} keys %$h;
    return $w[0];
}

# What to make of a failed request: {code, retryable, wait, context}
#   retryable: worth another try (rate limit, overload, network)
#   wait:      seconds the API asked to wait
#   context:   the conversation does not fit the context window of the model
sub classify_error {
    my ($code, $decoded, $text, $headers) = @_;
    my $e     = ref($decoded) eq 'HASH' ? $decoded->{error} : undef;
    my $ecode = ref($e) eq 'HASH' ? ($e->{code} // $e->{status} // '') : '';
    $code = $ecode if (!$code or $code == 200) and !ref($ecode) and $ecode =~ m/^\d{3}$/;
    my %i = (code => $code || 0);
    my $msg = join(' ', grep {defined and !ref} $text, ref($e) eq 'HASH' ? @{$e}{qw(message type code)} : $e);
    if($msg =~ m/context[ _](?:length|window|size)|maximum context|too many tokens|prompt is too long|exceeds? the (?:available )?context|reduce the length/i){
        $i{context} = 1;
        return \%i;
    }
    my $rate = ($i{code} == 429 or $msg =~ m/rate.?limit|too many requests/i) ? 1 : 0;
    $i{retryable} = 1
        if $rate
        or !$i{code} # no HTTP status at all: refused, reset, timeout
        or grep({$i{code} == $_} 408, 425, 500, 502, 503, 504, 529)
        or $msg =~ m/overloaded|temporarily|try again/i;
    $i{wait} = rate_limit_wait($headers, $decoded) if $rate;
    return \%i;
}

# One request to the LLM with the given messages, streamed to the terminal
# (not shown with quiet => 1).
# Returns ($content, $error, $info): $content is what the assistant said so
# far (can be partial on error), $error is undef on success, $info has the
# token usage, timing and, on error, what classify_error() says.
sub request_completion {
    my ($msgs, %o) = @_;
    my $req = build_request($msgs);
    return ('', "ERROR: no raw prompt format known for model '".($SESSION_MODEL // '')."' (AI_RAW)", {})
        unless defined $req;
    log::info($req);
    log::info("Requesting completion from AI API $AI_URL with ".(length($api_key // '') ? 'an' : 'no')." api key");

    STDOUT->autoflush(1);
    STDERR->autoflush(1);
    my $info = {t_start => Time::HiRes::time()};
    my $printer = new_printer($o{quiet} ? sub {} : undef);
    # the status line tells that we wait, until there is something to show
    $TUI->set('model', $o{quiet} ? 'summarizing' : 'waiting for model');
    my $st = new_stream(sub {
        $info->{t_first} //= Time::HiRes::time();
        $TUI->unset('model') unless $o{quiet};
        &{$printer->{emit}}(@_);
    });
    my $r = utils::http("post", $AI_URL, $req, $api_key, sub {
        my ($ch, $raw) = @_;
        $raw //= $ch; # WWW::Curl::Easy: <data>, <user_ref>, Net::Curl::Easy: <handle>, <data>
        log::info("GOT STREAM ".do {local $_ = $raw; chomp; chomp; $_});
        return 0 if utils::aborted(); # stops the transfer
        &{$st->{feed}}($raw);
        return length($raw);
    });
    $TUI->unset('model');
    &{$st->{finish}}();
    &{$printer->{finish}}();
    $info->{t_end} = Time::HiRes::time();
    $info->{usage} = $st->{usage};

    return ($st->{content}, "interrupted", $info) if utils::aborted();
    my ($err, $c) = completion_result($st, !defined $r, $utils::http_error, $utils::http_code, \%utils::http_headers);
    $info->{$_} = $c->{$_} for keys %$c;
    return ($st->{content}, $err, $info);
}

# the JSON body of a completion request for these messages, undef when the
# provider has no format for it
sub build_request {
    my ($msgs) = @_;
    my $w   = $::ORIG_ENV{AI_RAW} ? "raw" : "req";
    my $fn  = "provider::$AI_PROVIDER"->can($w) // provider->can($w);
    my $req = &{$fn}(@$msgs)
        or return;
    return $::JSON->encode($req);
}

# How a request ended: ($error, {what classify_error() says}), $error is undef
# when all is well. $st is the stream state the reply went through.
sub completion_result {
    my ($st, $failed, $http_error, $code, $headers) = @_;
    my $err;
    if($st->{error}){
        $err = format_api_error($st->{error});
    } elsif($failed){
        log::info("GOT ERROR RESPONSE REMAINING >>$st->{rbuf}<<");
        $err = format_api_error(undef, join(": ", grep {length} $http_error // '', $st->{rbuf} =~ s/\s+\z//r));
    } elsif(!$st->{events} and $st->{rbuf} =~ m/\S/){
        return ("ERROR: unexpected reply: $st->{rbuf}", {});
    }
    return (undef, {}) unless defined $err;
    return ($err, classify_error($code, $st->{error}, $err, $headers));
}

# the system prompt of a sub-agent: the prompt of the session, the tools
# (without the agent tool) and what it is there for
sub subagent_prompt {
    my $prompt = slurp($PROMPT_FILE // '') // '';
    $prompt .= prompt::coder::prompt(exclude => ['agent']);
    $prompt .= "\n\nYou are a sub-agent: another agent gave you the task below, the user is not here and you cannot ask questions. "
              ."Work on it with your tools. Your final answer, the one without a tool call, is all the other agent gets to see: "
              ."report what you found or did, complete but without the detours.\n";
    return $prompt;
}

#------------------------------------------------------------------------------
# token usage: counted per session, used for the context window and the budget

sub load_usage {
    my $u = eval {JSON::XS::decode_json(slurp("$AI_SESSION_DIR/usage") // '{}')};
    return ref($u) eq 'HASH' ? $u : {};
}

sub save_usage {
    my ($u) = @_;
    spew("$AI_SESSION_DIR/usage", JSON::XS->new->utf8->canonical->encode($u)."\n");
    return;
}

sub chars_of {
    my $n = 0;
    $n += length(to_bytes($_->{content})) for @_;
    return $n;
}

# tokens of messages: an estimate from their size, calibrated with what the
# API reported for this session so far
sub estimate_tokens {
    my (@msgs) = @_;
    my $cpt = load_usage()->{chars_per_token} || 3.5;
    return int(chars_of(@msgs) / $cpt) + 4 * @msgs;
}

# Account one request. Returns (prompt tokens, completion tokens, estimated?)
sub record_usage {
    my ($msgs, $resp, $info) = @_;
    my $u  = load_usage();
    my $us = ref($info->{usage}) eq 'HASH' ? $info->{usage} : {};
    my ($in, $out, $est) = ($us->{prompt_tokens}, $us->{completion_tokens}, 0);
    if(defined $in and $in =~ m/^\d+$/ and $in > 0){
        $out //= ($us->{total_tokens} // $in) - $in;
        # learn how big a token is for this model and this kind of text
        if($in >= 50){
            my $cpt = chars_of(@$msgs) / $in;
            $cpt = 1.5 if $cpt < 1.5;
            $cpt = 8   if $cpt > 8;
            $u->{chars_per_token} = sprintf("%.2f", $cpt) + 0;
        }
    } else {
        $est = 1;
        $in  = estimate_tokens(@$msgs);
        $out = int(length(to_bytes($resp)) / ($u->{chars_per_token} || 3.5));
        $u->{estimated} = 1;
    }
    $u->{requests}++;
    $u->{prompt_tokens}     += $in;
    $u->{completion_tokens} += $out;
    $u->{total_tokens}       = $u->{prompt_tokens} + $u->{completion_tokens};
    $u->{last_prompt_tokens}     = $in;
    $u->{last_completion_tokens} = $out;
    save_usage($u);
    return ($in, $out, $est);
}

sub usage_line {
    my ($in, $out, $est, $info) = @_;
    my $u = load_usage();
    my $s = sprintf("tokens: %s%d in + %d out, session %d", $est ? '~' : '', $in, $out, $u->{total_tokens} // 0);
    if(my $budget = $::ORIG_ENV{AI_TOKEN_BUDGET}){
        $s .= sprintf(" of %d", $budget);
    }
    if(my $limit = context_limit()){
        $s .= sprintf(" | context %d%% of %d", 100 * ($in + $out) / $limit, $limit);
    }
    if($info->{t_end} and $info->{t_start}){
        $s .= sprintf(" | %.1fs", $info->{t_end} - $info->{t_start});
        my $gen = $info->{t_end} - ($info->{t_first} // $info->{t_end});
        $s .= sprintf(", %.1f tok/s", $out / $gen) if $out > 1 and $gen > 0.05;
    }
    return "[$s]";
}

# true (and says so) when the session used up AI_TOKEN_BUDGET
sub over_budget {
    my $budget = $::ORIG_ENV{AI_TOKEN_BUDGET}
        or return 0;
    my $used = load_usage()->{total_tokens} // 0;
    return 0 if $used < $budget;
    log::error("${colors::red_color}token budget used up: $used of $budget tokens (AI_TOKEN_BUDGET). '/usage reset' starts counting again${colors::reset_color}");
    return 1;
}

#------------------------------------------------------------------------------
# context management: keep the conversation within the context window

our %MODEL_CONTEXT;  # model id => context size, from the model list of the API
our $SERVER_CONTEXT; # context size of a local server (llama.cpp /props)

# context window in tokens, 0 when unknown
sub context_limit {
    my $env = $::ORIG_ENV{AI_CONTEXT_TOKENS};
    return $env + 0 if defined $env and $env =~ m/^\d+$/;
    return $MODEL_CONTEXT{$SESSION_MODEL // ''} || $SERVER_CONTEXT || 0;
}

sub is_tool_result {
    my ($m) = @_;
    return (($m->{role} // '') eq 'user' and ($m->{content} // '') =~ m/\A\[\w+ (?:RESULT_d170|ERROR_9a78)\n/) ? 1 : 0;
}

# old tool output is the first thing that can go: keep the start and the end
sub prune_tool_results {
    my (@msgs) = @_;
    my $changed = 0;
    my @r = map {
        my $m = $_;
        if(is_tool_result($m) and length($m->{content}) > 600){
            my $c = $m->{content};
            my $cut = length($c) - 400;
            $m = {%$m, content => substr($c, 0, 300)."\n[... $cut characters of old tool output removed to save context ...]\n".substr($c, -100)};
            $changed++;
        }
        $m;
    } @msgs;
    return ($changed, @r);
}

# Make the conversation smaller. Old tool output is cut first. If that is not
# enough the older part is replaced by a summary written by the model (or just
# dropped: AI_CONTEXT_SUMMARY=0, or when the summary fails). The recent
# messages stay as they are, removed messages go to the "chat.archive" file.
# Returns true when the conversation was changed.
sub compact_context {
    my (%o) = @_; # summarize => 1: always summarize, quiet => 1
    my @msgs   = load_messages();
    my $before = estimate_tokens(@msgs);
    my $limit  = context_limit();
    my $target = int(($limit || $before) * 0.5); # where to end up
    my $keep   = int($target * 0.5);             # recent messages, kept as they are
    my @sys    = (@msgs and ($msgs[0]{role} // '') eq 'system') ? (shift @msgs) : ();
    return 0 unless @msgs;

    # the tail: the recent messages, starting at a user message if possible
    my ($cut, $sum) = (scalar(@msgs), 0);
    while($cut > 0){
        my $t = estimate_tokens($msgs[$cut - 1]);
        last if $cut < @msgs and $sum + $t > $keep;
        $sum += $t;
        $cut--;
    }
    $cut++ while $cut < $#msgs and ($msgs[$cut]{role} // '') ne 'user';
    my @head = @msgs[0 .. $cut - 1];
    my @tail = @msgs[$cut .. $#msgs];
    my $say  = sub {
        my ($how, @new) = @_;
        return if $o{quiet};
        print "${colors::cyan_color}[context: $how, ~$before -> ~".estimate_tokens(@new)." tokens]${colors::reset_color}\n";
    };
    my $archive = sub {
        my (@gone) = @_;
        return unless @gone;
        open(my $fh, '>>', "$AI_SESSION_DIR/chat.archive")
            or die "Failed to write to $AI_SESSION_DIR/chat.archive: $!\n";
        print {$fh} $::JSON->encode($_)."\n" for @gone;
        close($fh);
    };

    # 1. old tool output
    my ($pruned, @phead) = prune_tool_results(@head);
    if($pruned and !$o{summarize} and estimate_tokens(@sys, @phead, @tail) <= $target){
        &{$archive}(@head);
        write_messages(@sys, @phead, @tail);
        &{$say}("old tool output removed from $pruned messages", @sys, @phead, @tail);
        return 1;
    }

    # nothing old worth a summary: all that is left is big recent tool output
    if(@head < 2 or estimate_tokens(@head) < $before * 0.1){
        return 0 unless @tail > 2;
        my ($n, @ptail) = prune_tool_results(@tail[0 .. $#tail - 2]);
        return 0 unless $n;
        &{$archive}(@tail[0 .. $#tail - 2]);
        write_messages(@sys, @phead, @ptail, @tail[-2, -1]);
        &{$say}("tool output removed from $n messages", @sys, @phead, @ptail, @tail[-2, -1]);
        return 1;
    }

    # 2. a summary of the older part, written by the model
    my $summary;
    if(($::ORIG_ENV{AI_CONTEXT_SUMMARY} // 1) ne '0'){
        print "${colors::cyan_color}[context: summarizing ".scalar(@head)." older messages...]${colors::reset_color}\n"
            unless $o{quiet};
        my $cpt = load_usage()->{chars_per_token} || 3.5;
        my $max = int($target * $cpt);
        my $per = int($max / @phead);
        $per = 2000 if $per < 2000;
        my $transcript = join("\n\n", map {
            my $c = $_->{content} // '';
            $c = substr($c, 0, $per - 200)."\n[...]\n".substr($c, -150) if length($c) > $per;
            uc($_->{role} // 'user').":\n$c";
        } @phead);
        # the task is at the start, the state at the end: cut in the middle
        $transcript = substr($transcript, 0, int($max / 2))."\n[...]\n".substr($transcript, -int($max / 2))
            if length($transcript) > $max;
        my @req = (
            {role => 'system', content => "You compact conversations between a user and a coding agent so that the work can continue with less context."},
            {role => 'user',   content => "$transcript\n\n---\nSummarize the conversation above: the goals of the user, the decisions, what was done (files, commands and their relevant results), the current state and what is left to do. Be specific, keep file names, identifiers and error messages. Only the summary, no preamble, no tool calls."},
        );
        my ($resp, $err, $info) = request_completion(\@req, quiet => 1);
        return 0 if utils::aborted();
        record_usage(\@req, $resp, $info) unless defined $err and !length($resp);
        $summary = strip_thinking($resp) =~ s/\A\s+//r =~ s/\s+\z//r;
        if(defined $err or !length($summary)){
            log::error("${colors::red_color}summary failed".(defined $err ? ": $err" : "")."${colors::reset_color}");
            $summary = undef;
        }
    }

    # 3. or without one
    my $note = defined $summary
        ? "[Summary of the conversation so far, the older messages were removed to save context]\n$summary"
        : "[The older messages of this conversation were removed to save context]";
    my @new = (@sys, {role => 'user', content => $note}, @tail);
    &{$archive}(@head);
    write_messages(@new);
    &{$say}((defined $summary ? "summarized" : "dropped")." ".scalar(@head)." older messages", @new);
    return 1;
}

# before a request: compact when the conversation gets close to the limit
sub manage_context {
    my $limit = context_limit()
        or return 0;
    my $threshold = $::ORIG_ENV{AI_CONTEXT_THRESHOLD} // 0.8;
    return 0 if estimate_tokens(load_messages()) <= $limit * $threshold;
    return compact_context();
}

#------------------------------------------------------------------------------

# seconds to wait before retry number $attempt: what the API asked for, else
# exponential backoff with some jitter
sub retry_delay {
    my ($attempt, $asked) = @_;
    return $asked + 0.1 if defined $asked and $asked >= 0;
    my $base = $::ORIG_ENV{AI_RETRY_DELAY} // 2;
    my $d = $base * 2 ** ($attempt - 1);
    $d = 60 if $d > 60;
    return $d * (0.75 + rand(0.5));
}

# The agent loop: send the conversation, show the answer, run the tools the
# model asked for, send the results back, until the model has nothing left to
# run. Every step is appended to the chat file, each request is built from it.
sub chat_completion {
    my ($input) = @_;
    log::info("User input: $input");
    return if over_budget();
    append_messages({role => 'user', content => to_text($input)});

    my $max_turns = $::ORIG_ENV{AI_MAX_TURNS} // 50;
    my $retries   = $::ORIG_ENV{AI_RETRIES} // 4;
    my $max_wait  = $::ORIG_ENV{AI_RETRY_MAX_WAIT} // 120;
    my $turn = 0;
    my $compacted = 0; # after a "context too long" error, once per input
    while(1){
        last if utils::aborted();
        if($max_turns and ++$turn > $max_turns){
            log::error("${colors::red_color}stopped after $max_turns tool turns (AI_MAX_TURNS)${colors::reset_color}");
            last;
        }
        last if $turn > 1 and over_budget();
        manage_context();

        my (@msgs, $resp, $err, $info);
        my $attempt = 0;
        while(1){
            @msgs = load_messages();
            ($resp, $err, $info) = request_completion(\@msgs);
            last unless defined $err;
            last if utils::aborted();
            last if length(strip_thinking($resp) =~ s/\A\s+//r); # part of an answer: keep it
            if($info->{context} and !$compacted++ and compact_context()){
                next;
            }
            last unless $info->{retryable} and $attempt < $retries;
            my $wait = retry_delay(++$attempt, $info->{wait});
            if($wait > $max_wait){
                $err .= sprintf(" (asked to wait %ds, more than AI_RETRY_MAX_WAIT=%d)", $wait, $max_wait);
                last;
            }
            print "${colors::red_color}$err${colors::reset_color}\n";
            printf "%s[retry %d of %d in %.1fs, ctrl-C to stop]%s\n", $colors::cyan_color, $attempt, $retries, $wait, $colors::reset_color;
            utils::wait_abortable($wait)
                or last;
        }

        # what is kept: the answer without the thinking
        my $answer = strip_thinking($resp);
        $answer =~ s/\A\s+//;
        append_messages({role => 'assistant', content => $answer})
            if length($answer);
        if(!defined $err or length($resp)){
            my @u = record_usage(\@msgs, $resp, $info);
            print "${colors::cyan_color}".usage_line(@u, $info)."${colors::reset_color}\n"
                if ($::ORIG_ENV{AI_SHOW_USAGE} // 1);
        }
        if(defined $err){
            if(utils::aborted()){
                print "${colors::red_color}[interrupted]${colors::reset_color}\n";
            } else {
                log::error(${colors::red_color}.$err.${colors::reset_color});
            }
            last;
        }
        last unless length($answer);

        # handle tools
        my ($newturns, undef, $r) = handle_llm_response(\$answer);
        append_messages(@{$r // []});
        last unless $newturns;
    }
    return;
}

#------------------------------------------------------------------------------
# sessions, models, prompts

# system prompt of a session: its prompt file, plus what the template generates
# (the tools section for e.g. "coder")
sub system_prompt {
    my ($session_dir) = @_;
    $session_dir //= $AI_SESSION_DIR;
    my $prompt   = slurp("$session_dir/prompt") // '';
    my $template = slurp("$session_dir/template") // $AI_PROMPT_TEMPLATE // 'default';
    $template =~ s/\s+//g;
    if($template =~ m/^\w+$/ and UNIVERSAL::can("prompt::${template}", "prompt")){
        log::info("PROMPT check for 'prompt::${template}'");
        no strict "refs";
        $prompt .= &{"prompt::${template}::prompt"}() // "";
    }
    return $prompt;
}

sub init_session {
    my ($session) = @_;
    my $session_dir = "$SESSIONS_DIR/$session";
    -d $session_dir or mkdir $session_dir or die "Failed to create $session_dir: $!\n";

    my $p_file = "$session_dir/prompt";
    my $s_file = "$session_dir/chat";
    my $clear  = $::ORIG_ENV{AI_CLEAR} // 0;

    log::info("checking setup: AI_CLEAR=$clear, $p_file, $s_file, $AI_PROMPT_TEMPLATE_FILE");
    if(!-s $p_file or $clear){
        my $prompt = slurp($AI_PROMPT_TEMPLATE_FILE);
        if(defined $prompt){
            log::info("using/updating $AI_PROMPT_TEMPLATE_FILE for prompt");
        } else {
            log::info("no prompt file $AI_PROMPT_TEMPLATE_FILE, clearing $p_file");
        }
        spew($p_file, $prompt // "");
        spew("$session_dir/template", "$AI_PROMPT_TEMPLATE\n");
    }
    if(!-s $s_file or $clear){
        spew($s_file, $::JSON->encode({role => 'system', content => to_text(system_prompt($session_dir))})."\n");
    }
    return;
}

# forget the conversation, keep the system prompt
sub reset_chat {
    write_messages({role => 'system', content => to_text(system_prompt())});
    return;
}

sub get_sessions {
    my @sessions = glob("$SESSIONS_DIR/*");
    return  [sort map {$_ =~ s/.*\///; $_} grep {-d $_} @sessions];
}

sub list_sessions {
    foreach my $s (@{get_sessions()}) {
        if ($s eq $AI_SESSION) {
            print "${colors::green_color}* $s${colors::reset_color}\n";
        } else {
            print "  $s\n";
        }
    }
}

sub switch_session {
    my ($new_session) = @_;
    $new_session = utils::trim($new_session // '');
    if(valid_session_name($new_session) and -d "$SESSIONS_DIR/$new_session"){
        use_session($new_session);
        print "Switched to session: $new_session\n";
    } else {
        print "Session '$new_session' does not exist.\n";
    }
}

sub create_session {
    my ($name) = @_;
    $name = utils::trim($name // '');
    if (!valid_session_name($name)) {
        print "Invalid session name '$name' (use letters, digits, '.', '_' and '-').\n";
        return;
    }
    if (-d "$SESSIONS_DIR/$name") {
        print "Session '$name' already exists.\n";
        return;
    }
    init_session($name);
    print "Created session '$name'.\n";
    refresh_session_completions();
    switch_session($name);
}

sub delete_session {
    my ($name) = @_;
    $name = utils::trim($name // '');
    if (!valid_session_name($name) or !-d "$SESSIONS_DIR/$name") {
        print "Session '$name' does not exist.\n";
        return;
    }
    if ($name eq $AI_SESSION) {
        print "Cannot delete the current session.\n";
        return;
    }
    utils::load_cpan("File::Path");
    File::Path::remove_tree("$SESSIONS_DIR/$name");
    print "Deleted session '$name'.\n";
    refresh_session_completions();
}

sub rename_session {
    my ($old, $new) = @_;
    $old = utils::trim($old // '');
    $new = utils::trim($new // '');
    if (!valid_session_name($old) or !-d "$SESSIONS_DIR/$old") {
        print "Session '$old' does not exist.\n";
        return;
    }
    if (!valid_session_name($new)) {
        print "Invalid session name '$new' (use letters, digits, '.', '_' and '-').\n";
        return;
    }
    if (-d "$SESSIONS_DIR/$new") {
        print "Session '$new' already exists.\n";
        return;
    }
    if (rename("$SESSIONS_DIR/$old", "$SESSIONS_DIR/$new")) {
        use_session($new) if $old eq $AI_SESSION;
        print "Renamed session '$old' to '$new'.\n";
        refresh_session_completions();
    } else {
        print "Failed to rename session: $!\n";
    }
}

sub switch_model {
    my ($new_model) = @_;
    $new_model = clean_model_name($new_model) || clean_model_name($::ORIG_ENV{AI_MODEL});
    if(!length($new_model)){
        print "No model given.\n";
        return;
    }
    if(!eval {spew("$AI_SESSION_DIR/model", $new_model); 1}){
        print "Failed to switch model: $@";
        return;
    }
    $SESSION_MODEL = $new_model;
    print "Switched model to '$new_model'.\n";
}

# the model list of the API, undef when it can't be fetched
sub fetch_models {
    my $response = eval {utils::http("get", "$AI_ENDPOINT_URL/v1/models", undef, $api_key)};
    return unless $response;
    my $resp = eval {JSON::XS::decode_json($response)};
    my @models;
    if (ref($resp) eq 'HASH' and ref($resp->{data}) eq 'ARRAY') {
        @models = @{$resp->{data}};
    } elsif (ref($resp) eq 'ARRAY') {
        @models = @$resp;
    } else {
        return;
    }
    foreach my $m (grep {ref($_) eq 'HASH' and defined $_->{id}} @models){
        my $ctx = $m->{context_length} // $m->{context_window}
               // (ref($m->{meta}) eq 'HASH' ? $m->{meta}{n_ctx} : undef);
        $MODEL_CONTEXT{$m->{id}} = $ctx + 0 if defined $ctx and $ctx =~ m/^\d+$/ and $ctx > 0;
    }
    return [grep {defined and length} map {ref($_) eq 'HASH' ? $_->{id} : $_} @models];
}

# context size a local llama.cpp server runs with
sub fetch_server_context {
    my $response = eval {utils::http("get", "$AI_ENDPOINT_URL/props", undef, $api_key)};
    my $props = $response ? eval {JSON::XS::decode_json($response)} : undef;
    return unless ref($props) eq 'HASH' and ref($props->{default_generation_settings}) eq 'HASH';
    my $ctx = $props->{default_generation_settings}{n_ctx};
    $SERVER_CONTEXT = $ctx + 0 if defined $ctx and $ctx =~ m/^\d+$/ and $ctx > 0;
    return $SERVER_CONTEXT;
}

sub list_models {
    my $models = fetch_models();
    if(!$models){
        log::error("Failed to fetch models".($utils::http_error ? ": $utils::http_error" : ""));
        print "Current model: ".($SESSION_MODEL || '<server default>')."\n";
        return;
    }
    @MODELS = @$models;
    $cmds->{'/model'} = {map {($_, sub {0})} @MODELS} if $cmds;
    foreach my $id (@MODELS) {
        if ($id eq ($SESSION_MODEL // '')) {
            print "${colors::green_color}* $id${colors::reset_color}\n";
        } else {
            print "  $id\n";
        }
    }
    return;
}

sub prompt_templates {
    return [sort map {s/.*\///r} grep {-f $_} glob("$FindBin::Bin/ai/*")];
}

sub list_prompts {
    my $current = slurp($PROMPT_FILE) // '';
    foreach my $name (@{prompt_templates()}) {
        my $data = slurp("$FindBin::Bin/ai/$name") // next;
        if ($current eq $data) {
            print "${colors::green_color}* $name${colors::reset_color}\n";
        } else {
            print "  $name\n";
        }
    }
}

# use another prompt template for this session, the conversation is kept
sub switch_prompt {
    my ($new_prompt) = @_;
    $new_prompt = utils::trim($new_prompt // '') =~ s/.*\///r;
    my $template = $new_prompt =~ m/^[\w.\-]+$/ ? slurp("$FindBin::Bin/ai/$new_prompt") : undef;
    if(!defined $template){
        print "Failed to read prompt template '$new_prompt'.\n";
        return;
    }
    if(!eval {
        spew($PROMPT_FILE, $template);
        spew("$AI_SESSION_DIR/template", "$new_prompt\n");
        my @msgs = load_messages();
        shift @msgs if @msgs and ($msgs[0]{role} // '') eq 'system';
        write_messages({role => 'system', content => to_text(system_prompt())}, @msgs);
        1;
    }){
        print "Failed to switch prompt: $@";
        return;
    }
    print "Switched system prompt.\n";
}

# add the files of the current directory that match a regex to the chat
sub add_files {
    my ($rx) = @_;
    my $dir_rx = eval {qr/$rx/};
    if(!$dir_rx){
        print "Bad pattern '$rx': $@";
        return;
    }
    my @ignore = map {glob($_)} grep {length and !m/^#/} map {utils::trim($_)}
        split m/\n/, slurp('.aiignore') // '';
    opendir(my $dh, Cwd::cwd())
        or return;
    foreach my $file (sort readdir($dh)) {
        next if $file =~ m/^\./;
        next unless -f $file;
        next if $file !~ m/$dir_rx/;
        next if grep {$file eq $_} @ignore;
        my $data = slurp($file);
        next unless length($data // "");
        $data = "$file:\n".'```'."\n".$data."\n".'```'."\n";
        append_messages({role => 'user', content => to_text($data)});
        print "${colors::green_color}✓${colors::reset_color} added $file to chat\n";
    }
    closedir $dh;
    return;
}

#------------------------------------------------------------------------------
# slash commands: the one table that drives execution, /help and completion
#   run:      sub($args) returns true to leave the chat
#   complete: sub() returns the completion (sub)tree, default none

our @COMMANDS;
@COMMANDS = (
    '/exit'  => {
        help => 'leave the chat',
        run  => sub {1},
    },
    '/quit'  => {
        help => 'leave the chat',
        run  => sub {1},
    },
    '/help' => {
        help => 'show this list',
        run  => sub {
            my %c = @COMMANDS;
            printf "  %-34s %s\n", $c{$_}{usage} // $_, $c{$_}{help} for grep {!ref} @COMMANDS;
            return 0;
        },
    },
    '/clear' => {
        help => 'forget the conversation, keep the system prompt',
        run  => sub {reset_chat(); 0},
    },
    '/history' => {
        help => 'show the input history',
        run  => sub {print slurp($HISTORY_FILE) // ''; 0},
    },
    '/debug' => {
        help => 'enable debug logging',
        run  => sub {$::DEBUG = 1; 0},
    },
    '/nodebug' => {
        help => 'disable debug logging',
        run  => sub {$::DEBUG = 0; 0},
    },
    '/tools' => {
        help => 'list the tools the model can call',
        run  => sub {
            print "Available tools:\n";
            foreach my $name (sort keys %$tools::TOOLS) {
                print "  $name: $tools::TOOLS->{$name}{description}\n";
            }
            return 0;
        },
    },
    '/system' => {
        usage => '/system <text>',
        help  => 'add a system message to the conversation',
        run   => sub {
            my ($args) = @_;
            if(length($args)){
                append_messages({role => 'system', content => to_text($args)});
            } else {
                print "Usage: /system <text>\n";
            }
            return 0;
        },
    },
    '/files' => {
        usage => '/files [regex]',
        help  => 'add matching files of the current directory to the chat',
        run   => sub {add_files($_[0]); 0},
    },
    '/chdir' => {
        usage => '/chdir <dir>',
        help  => 'change the working directory (also /cd)',
        run   => sub {
            my ($args) = @_;
            chdir(length($args) ? $args : ($::ORIG_ENV{HOME} // '/'))
                or print "Failed to change directory to $args: $!\n";
            return 0;
        },
    },
    '/ls' => {
        help => 'list the working directory',
        run  => sub {
            if(opendir(my $dh, Cwd::cwd())){
                print "$_\n" for sort grep {!m/^\./} readdir($dh);
                closedir $dh;
            }
            return 0;
        },
    },
    '/pwd' => {
        help => 'print the working directory',
        run  => sub {print Cwd::cwd()."\n"; 0},
    },
    '/session' => {
        usage => '/session [list|create|delete|rename|switch] [name]',
        help  => 'manage sessions, "/session <name>" switches',
        run   => sub {
            my ($args) = @_;
            my ($sub, $rest) = split m/\s+/, $args, 2;
            $sub  //= '';
            $rest //= '';
            if ($sub eq '' or ($sub eq 'list' and $rest eq '')) {
                list_sessions();
            } elsif ($sub eq 'create' and length($rest)) {
                create_session($rest);
            } elsif ($sub eq 'delete' and length($rest)) {
                delete_session($rest);
            } elsif ($sub eq 'rename' and $rest =~ m/^(\S+)\s+(\S+)$/) {
                rename_session($1, $2);
            } elsif ($sub eq 'switch' and length($rest)) {
                switch_session($rest);
            } elsif ($sub =~ m/^(?:create|delete|rename|switch)$/) {
                print "Usage: /session $sub <name>".($sub eq 'rename' ? ' <new name>' : '')."\n";
            } else {
                switch_session($args);
            }
            return 0;
        },
        complete => sub {
            my $s = get_sessions();
            return {
                'list'   => sub {0},
                'create' => sub {0},
                'delete' => {map {($_, sub {0})} @$s},
                'rename' => {map {($_, sub {0})} @$s},
                'switch' => {map {($_, sub {0})} @$s},
                map {($_, sub {0})} @$s,
            };
        },
    },
    '/model' => {
        usage => '/model [name]',
        help  => 'list the models, or set the model of this session',
        run   => sub {
            my ($args) = @_;
            length($args) ? switch_model($args) : list_models();
            return 0;
        },
        complete => sub {return +{map {($_, sub {0})} @MODELS}},
    },
    '/usage' => {
        usage => '/usage [reset]',
        help  => 'token usage of this session, "reset" starts counting again',
        run   => sub {
            my ($args) = @_;
            if($args eq 'reset'){
                my $u = load_usage();
                save_usage({map {($_ => $u->{$_})} grep {$_ eq 'chars_per_token'} keys %$u});
                print "Usage of session '$AI_SESSION' reset.\n";
                return 0;
            }
            my $u = load_usage();
            my @msgs = load_messages();
            my $limit = context_limit();
            printf "requests:   %d\n", $u->{requests} // 0;
            printf "tokens:     %s%d in + %d out = %d%s\n", $u->{estimated} ? '~' : '',
                $u->{prompt_tokens} // 0, $u->{completion_tokens} // 0, $u->{total_tokens} // 0,
                $::ORIG_ENV{AI_TOKEN_BUDGET} ? " of $::ORIG_ENV{AI_TOKEN_BUDGET} (AI_TOKEN_BUDGET)" : "";
            printf "context:    ~%d tokens in %d messages%s\n", estimate_tokens(@msgs), scalar(@msgs),
                $limit ? sprintf(", %d%% of %d", 100 * estimate_tokens(@msgs) / $limit, $limit) : ", window size unknown (AI_CONTEXT_TOKENS)";
            return 0;
        },
        complete => sub {return +{reset => sub {0}}},
    },
    '/compact' => {
        help => 'summarize the older messages to free context',
        run  => sub {
            local $BUSY = 1;
            compact_context(summarize => 1)
                or print "Nothing to compact.\n";
            $::ABORT = 0;
            return 0;
        },
    },
    '/prompt' => {
        usage => '/prompt [name]',
        help  => 'list the prompt templates, or switch the system prompt',
        run   => sub {
            my ($args) = @_;
            length($args) ? switch_prompt($args) : list_prompts();
            return 0;
        },
        complete => sub {return +{map {($_, sub {0})} @{prompt_templates()}}},
    },
);
our %COMMANDS = (@COMMANDS, '/cd' => {@COMMANDS}->{'/chdir'});

# Runs a "/command": returns undef when $line is not one (it is chat then),
# 1 when the chat should end, 0 otherwise. A command is never sent to the LLM.
sub handle_command {
    my ($line) = @_;
    return unless defined $line and $line =~ m{^/};
    log::info("Command: $line");
    my ($name, $args) = $line =~ m{^(/\S*)\s*(.*?)\s*$}s;
    my $c = $COMMANDS{$name};
    if (!$c) {
        print "Unknown command: $name (try /help)\n";
        return 0;
    }
    my $r = eval {&{$c->{run}}($args)};
    if ($@) {
        print "${colors::red_color}$name failed: $@${colors::reset_color}";
        return 0;
    }
    return $r ? 1 : 0;
}

# build the completion tree out of the command table
sub setup_commands {
    if (!@MODELS and $AI_ENDPOINT_URL) {
        @MODELS = @{fetch_models() // []};
        fetch_server_context()
            if $::ORIG_ENV{AI_LOCAL_SERVER} and !defined $::ORIG_ENV{AI_CONTEXT_TOKENS};
    }
    $cmds = {map {
        my $c = $COMMANDS{$_};
        ($_ => $c->{complete} ? &{$c->{complete}}() : $c->{run})
    } keys %COMMANDS};
    return;
}

sub refresh_session_completions {
    return unless $cmds;
    $cmds->{'/session'} = &{$COMMANDS{'/session'}{complete}}();
    return;
}

sub chat_word_completions_cli {
    my ($text, $line, $start, $end) = @_;
    $line =~ s/ +$//g;
    my $cfg = $cmds;
    my @wrd = split m/\s+/, $line, -1;
    log::info("W: >".join("rcs, ", @wrd)."<");
    foreach my $w (@wrd) {
        my @rcs = ();
        return '' if defined $cfg and ref($cfg) ne 'HASH';
        foreach my $k (sort keys %$cfg) {
            push @rcs, $k if !index($k, $w) or $k eq $w;
        }
        if(@rcs == 1 and exists $cfg->{$rcs[0]}){
            $cfg = $cfg->{$rcs[0]};
            if($rcs[0] ne $w){
                if ($wrd[-1] eq '' or ($w eq $wrd[-1] and $text)){
                    return $rcs[0];
                }
            } else {
                return $rcs[0] if $w eq $wrd[-1] and $text;
            }
        } else {
            my $common = lccs(@rcs);
            return '' unless length($common);
            return $common, @rcs if $common ne $w;
            return '', @rcs if $w eq $wrd[-1];
            $cfg = $cfg->{$w};
        }
    }
    if(ref($cfg) eq 'HASH'){
        return '', sort keys %$cfg;
    }
    return '';
}

sub lccs {
    my ($prefix, @strings) = @_;
    foreach my $string (@strings) {
        $prefix = substr $prefix, 0, length $string;
        chop $prefix until 0 == index $string, $prefix;
    }
    return $prefix;
}

sub exitshell {
    exit 0;
}

sub setup_readline {
    local $ENV{PERL_RL} = 'Gnu';
    local $ENV{TERM}    = $::ORIG_ENV{TERM} // 'vt220';
    my $sig_h = $SIG{INT} = sub {$::LOOP = 0};
    eval {
        utils::load_cpan("Term::ReadLine");
        utils::load_cpan("Term::ReadLine::Gnu");
    };
    if($@){
        print STDERR "Please install Term::ReadLine and Term::ReadLine::Gnu\n\nE.g.:\n  sudo apt install libterm-readline-gnu-perl\n";
        exit 1;
    }
    my $term = Term::ReadLine->new("aicli");
    my $attribs = $term->Attribs;
    $attribs->{catch_signals}  = 0;
    $attribs->{catch_sigwinch} = 0;
    $attribs->{event_hook}     = sub {
        die "EXIT WANTED: 6df87ccd-2c9a-4303-982c-54b60ebb2aa1\n"
            unless $::LOOP
    };
    $attribs->{horizontal_scroll_mode} = 0;
    $attribs->{attempted_completion_function} = \&chat_word_completions_cli;
    $attribs->{ignore_completion_duplicates}  = 1;
    $term->read_init_file("$BASE_DIR/inputrc");
    $term->ReadLine('Term::ReadLine::Gnu') eq 'Term::ReadLine::Gnu'
        or die "Term::ReadLine::Gnu needs to be loaded\n";
    $term->enableUTF8();
    $term->using_history();
    $term->ReadHistory($HISTORY_FILE);
    $term->clear_signals();
    $SIG{WINCH} = sub {
        $term->reset_screen_size();
        my ($n_rows, $n_cols) = $term->get_screen_size();
        $term->redisplay();
        return;
    };
    $SIG{INT} = $SIG{TERM} = sub {
        # ctrl-C while the LLM or a tool is busy: stop that turn, stay in the chat
        if($BUSY and ($_[0] // '') eq 'INT'){
            $::ABORT = 1;
            return;
        }
        $term->write_history($HISTORY_FILE);
        $term->clear_message();
        $term->crlf();
        $term->set_prompt("");
        $term->redisplay();
        $term->resize_terminal();
        $term->free_line_state();
        $term->cleanup_after_signal();
        return &$sig_h(@_) if defined $sig_h and ref($sig_h) eq 'CODE';
        return;
    };
    $term->add_defun("flag-insert-newline", sub {
        my ($c, $k) = @_;
        $::shift_enter_pressed = 1;
        $::P1OR2 = 1;
        $term->insert_text("\n");
        $term->redisplay();
        $attribs->{done} = 1;
        return 0;
    });
    $term->parse_and_bind('"\e[13;2u": flag-insert-newline');
    $term->clear_message();
    $term->on_new_line();
    $term->redisplay();
    $term->reset_screen_size();
    return $term;
}

sub get_chat_prompt {
    my ($f) = @_;
    # https://jafrog.com/2013/11/23/colors-in-terminal.html
    # https://ss64.com/bash/syntax-colors.html
    my $prompt_term1  =
            $::ORIG_ENV{AI_PS1}
        //   $colors::reset_color
            .$colors::blue_color3
            .'❲$AI_SESSION'.($SESSION_MODEL?'\[$SESSION_MODEL\]':'').'❳ ► '
            .$colors::reset_color;
    my $prompt_term2  =
            $::ORIG_ENV{AI_PS2}
        //   $colors::reset_color
            .$colors::blue_color3
            .'│ '
            .$colors::reset_color;
    my $ps1 = eval 'return "'.$prompt_term1.'"' || '► ';
    my $ps2 = eval 'return "'.$prompt_term2.'"' || '│ ';
    return $ps2 if $f;
    return $ps1;
}

# Reads what the user wants: returns the (multi-line) chat text, or undef when
# the chat is over. Slash commands are executed here, they never come out.
sub input_terminal {
    my ($term) = @_;
    $::T = $term // setup_readline();
    return sub {
        my $buf = '';
        my $mlm = 0;
        $::shift_enter_pressed = 0;
      READ_AGAIN:
        return unless $::LOOP;
        my $line = eval{$::T->readline(get_chat_prompt($::P1OR2))};
        if($@ and $@ !~ m/EXIT WANTED: 6df87ccd-2c9a-4303-982c-54b60ebb2aa1/){
            die $@;
        }
        return unless defined $line;
        return unless $::LOOP;
        log::info("CURRENT BUF: >>$buf<<LINE>>$line<<");
        $line //= "";
        # e.g. a regular command /
        if((!$mlm or $line =~ m/^$/ms) and length($buf)){
            $mlm = 0;
            $::P1OR2 = 0;
            log::info("BUF: >>$buf<<");
            $::T->addhistory($buf);
            $::T->write_history($HISTORY_FILE);
            chomp $buf;
            return $buf;
        }
        if($::shift_enter_pressed or $mlm){
            $::shift_enter_pressed = 0;
            $mlm = 1;
            $::P1OR2 = 1;
            $buf .= "$line\n" if length($line);
            goto READ_AGAIN;
        }
        if($line !~ m/^$/ms and !length($buf) and !$mlm){
            if($line =~ m{^/}){
                $::T->addhistory($line);
                $::T->write_history($HISTORY_FILE);
                my $r_val = handle_command($line);
                return if ($r_val // 0) == 1;
                goto READ_AGAIN;
            }
            $buf .= "$line\n";
            $mlm = 0;
            $::P1OR2 = 0;
            log::info("BUF: >>$buf<<");
            $::T->addhistory($buf);
            $::T->write_history($HISTORY_FILE);
            chomp $buf;
            return $buf;
        }
        $buf .= "$line\n" if length($line);
        goto READ_AGAIN;
    };
}

sub input_stdin {
    return sub {
        my $line = <STDIN>;
        return unless defined $line;
        if ($line =~ m|^/|) {
            chomp $line;
            return if (handle_command($line) // 0) == 1;
            return "";
        }
        return $line;
    };
}

sub chat_loop {
    $::LOOP = 1;
    my $input_cli_sub = -t STDIN ? input_terminal() : input_stdin();
    # the status line, animated by the event loop
    $TUI = tui->new();
    $loop::on_tick = sub {$TUI->tick()};
    $loop::on_idle = sub {$TUI->clear()};
    while($::LOOP){
        log::info("Waiting for user input...");
        $::ABORT = 0;
        my $chat_request = &{$input_cli_sub}();
        last unless $::LOOP;
        unless(defined $chat_request){
            print "\n" if -t STDIN;
            last;
        }
        next if $chat_request =~ m/^\s*$/;
        {
            local $BUSY = 1;
            eval {chat_completion($chat_request); 1}
                or log::error(${colors::red_color}.($@ =~ s/\s+\z//r).${colors::reset_color});
        }
    }
    return;
}

sub cleanup_chat {
    return unless $::T;
    return unless $$ == $MAIN_PID; # never from a forked tool process
    log::info("cleanup terminal");
    $::T->write_history($HISTORY_FILE);
    $::T->clear_message();
    $::T->set_prompt("");
    $::T->redisplay();
    $::T->resize_terminal();
    $::T->free_line_state();
    $::T->cleanup_after_signal();
    $::T = undef;
    return;
}

END {
    ai::cleanup_chat();
}

package agent;
# A sub-agent: its own conversation with the model and its own tool loop, for
# one task of the main agent. It is not a process and not a thread: it is a
# state machine whose HTTP request (a curl handle) and tools (forked children)
# live in the event loop, next to those of the other agents, so several of
# them work at the same time. Nothing of it is printed, the status line shows
# what each one does, the final answer goes back to the main agent.

use strict; use warnings;

our $SEQ = 0;
our %RUNNING; # id => agent
our @QUEUE;   # agents waiting for a free slot (AI_MAX_AGENTS)

sub new {
    my ($class, $task) = @_;
    my $self = bless {
        id       => ++$SEQ,
        task     => $task,
        msgs     => [
            {role => 'system', content => ai::to_text(ai::subagent_prompt())},
            {role => 'user',   content => ai::to_text($task)},
        ],
        turns    => 0,
        tools    => 0,
        attempt  => 0,
        activity => 'queued',
        done     => 0,
        result   => undef,
        error    => undef,
    }, $class;
    return $self;
}

# create an agent for a task and start it, or queue it when enough are running
sub launch {
    my ($task) = @_;
    my $self = agent->new($task);
    $ai::TUI->set("agent $self->{id}", sub {$self->status()});
    my $max = $::ORIG_ENV{AI_MAX_AGENTS} // 4;
    if($max and keys(%RUNNING) >= $max){
        push @QUEUE, $self;
    } else {
        $self->start();
    }
    return $self;
}

# drive the event loop until these agents are done
sub wait {
    my (@agents) = @_;
    loop::run(sub {!grep {!$_->{done}} @agents});
    return;
}

sub status {
    my ($self) = @_;
    return "agent $self->{id}: $self->{activity}".($self->{turns} ? ", turn ".($self->{turns} + 1) : "");
}

sub start {
    my ($self) = @_;
    $RUNNING{$self->{id}} = $self;
    $self->request();
    return;
}

sub request {
    my ($self) = @_;
    return $self->finish(undef, "interrupted") if utils::aborted();
    my $budget = $::ORIG_ENV{AI_TOKEN_BUDGET};
    return $self->finish(undef, "token budget used up (AI_TOKEN_BUDGET)")
        if $budget and (ai::load_usage()->{total_tokens} // 0) >= $budget;
    my $json = do {
        local $ai::SESSION_MODEL = $::ORIG_ENV{AI_AGENT_MODEL} || $ai::SESSION_MODEL;
        ai::build_request($self->{msgs});
    };
    return $self->finish(undef, "no request format for this model (AI_RAW)") unless defined $json;
    $self->{activity} = 'waiting for model';
    my $st = ai::new_stream(sub {
        my ($kind) = @_;
        $self->{activity} = $kind eq 'think' ? 'thinking' : 'answering';
    });
    my $info = {t_start => Time::HiRes::time()};
    loop::http(
        method  => 'post',
        url     => $ai::AI_URL,
        data    => $json,
        api_key => $ai::api_key,
        on_data => sub {
            my ($ch, $raw) = @_;
            $raw //= $ch; # WWW::Curl::Easy: <data>, <user_ref>, Net::Curl::Easy: <handle>, <data>
            $info->{t_first} //= Time::HiRes::time();
            &{$st->{feed}}($raw);
            return length($raw);
        },
        on_done => sub {
            my ($req) = @_;
            &{$st->{finish}}();
            $info->{t_end} = Time::HiRes::time();
            $info->{usage} = $st->{usage};
            my ($err, $c) = ai::completion_result($st, defined $req->{error}, $req->{error}, $req->{code}, $req->{headers});
            $info->{$_} = $c->{$_} for keys %$c;
            $self->response($st->{content}, $err, $info);
        },
    );
    return;
}

sub response {
    my ($self, $resp, $err, $info) = @_;
    ai::record_usage($self->{msgs}, $resp, $info)
        if !defined $err or length($resp);
    my $answer = ai::strip_thinking($resp) =~ s/\A\s+//r;
    if(defined $err){
        return $self->finish(undef, "interrupted") if utils::aborted();
        my $retries = $::ORIG_ENV{AI_RETRIES} // 4;
        if(!length($answer) and $info->{retryable} and $self->{attempt} < $retries){
            my $wait = ai::retry_delay(++$self->{attempt}, $info->{wait});
            if($wait <= ($::ORIG_ENV{AI_RETRY_MAX_WAIT} // 120)){
                $self->{activity} = "retry $self->{attempt} of $retries";
                loop::timer($wait, sub {$_[0] ? $self->finish(undef, "interrupted") : $self->request()});
                return;
            }
        }
        return $self->finish(length($answer) ? $answer : undef, $err);
    }
    $self->{attempt} = 0;
    return $self->finish(undef, "the model gave no answer") unless length($answer);
    push @{$self->{msgs}}, {role => 'assistant', content => $answer};
    my @calls = ai::parse_tool_calls(ai::to_bytes($answer));
    return $self->finish($answer) unless @calls;
    my $max_turns = $::ORIG_ENV{AI_MAX_TURNS} // 50;
    return $self->finish($answer, "stopped after $max_turns tool turns (AI_MAX_TURNS)")
        if $max_turns and ++$self->{turns} >= $max_turns;
    $self->{queue} = \@calls;
    $self->next_tool();
    return;
}

# run the tool calls of the last answer one after the other, then ask again
sub next_tool {
    my ($self) = @_;
    while(my $c = shift @{$self->{queue}}){
        my $got = sub {
            my ($result, $err) = @_;
            push @{$self->{msgs}}, {role => 'user', content => ai::to_text(ai::tool_response($c->{tool}, $result, $err))};
        };
        if(utils::aborted()){
            &{$got}("", "[ERROR] not executed, interrupted by user");
            next;
        }
        if(!$c->{args}){
            &{$got}("", ai::malformed_error($c));
            next;
        }
        $self->{activity} = $c->{k};
        $self->{tools}++;
        # in-process tools answer at once, forked ones later from the loop
        my ($in_call, $answered) = (1, 0);
        ai::execute_tool_async($c->{k}, $c->{tool}, $c->{args}, sub {
            &{$got}(@_);
            return $answered = 1 if $in_call;
            $self->next_tool();
        });
        $in_call = 0;
        return unless $answered;
    }
    $self->request();
    return;
}

sub finish {
    my ($self, $result, $err) = @_;
    return if $self->{done};
    @{$self}{qw(done result error activity)} = (1, $result, $err, 'done');
    delete $RUNNING{$self->{id}};
    $ai::TUI->unset("agent $self->{id}");
    # what it did, for whoever wants to know: sessions/<name>/agents/<n>.chat
    eval {
        my $dir = "$ai::AI_SESSION_DIR/agents";
        -d $dir or mkdir $dir or die "$dir: $!\n";
        ai::spew(sprintf("%s/%d-%03d.chat", $dir, $^T, $self->{id}),
            join('', map {$::JSON->encode($_)."\n"} @{$self->{msgs}}));
        1;
    } or log::info("agent transcript not saved: $@");
    # the next one in line
    while(@QUEUE){
        my $next = shift @QUEUE;
        if(utils::aborted()){
            $next->finish(undef, "interrupted");
            next;
        }
        $next->start();
        last;
    }
    return;
}

package model;

use strict; use warnings;

sub transform {
    my (@jstr) = @_;
    my $model = $SESSION_MODEL || $::ORIG_ENV{AI_MODEL};
    my %r = (
        n_predict    => $::ORIG_ENV{AI_TOKENS}      // 100_000,
        temperature  => $::ORIG_ENV{AI_TEMPERATURE} // 0.6,
        stream       => $Types::Serialiser::true,
        model        => $model,
    );
    if($model =~ m/qwen/i){
        my $s_t = "<|im_start|>";
        my $e_t = "<|im_end|>";
        my $msg = join("", map {"${s_t}$_->{role}\n$_->{content}${e_t}\n"} @jstr);
        $msg   .= "${s_t}assistant";
        return {%r, prompt => $msg, stop => [$e_t]};
    }
    return;
}

package model::qwen;

package provider;

use strict; use warnings;

*raw = *model::transform;

sub req {
    my (@jstr) = @_;
    my $model = $SESSION_MODEL || $::ORIG_ENV{AI_MODEL};
    my $req = {
        ($model ? (model => $model):()),
        max_tokens   => $::ORIG_ENV{AI_TOKENS}      // 100_000,
        temperature  => $::ORIG_ENV{AI_TEMPERATURE} // 0.6,
        top_p        => $::ORIG_ENV{AI_TOP_P}       // 0.95,
        top_k        => $::ORIG_ENV{AI_TOP_K}       // 20,
        min_p        => $::ORIG_ENV{AI_MIN_P}       // 0.0,
        stream       => $Types::Serialiser::true,
        messages     => \@jstr,
    };
    # token usage in the last chunk of the stream
    $req->{stream_options} = {include_usage => $Types::Serialiser::true}
        if ($::ORIG_ENV{AI_USAGE} // 1);

    return $req;
}

package provider::openrouter;

use strict; use warnings;
use base qw(provider);

*raw = *provider::raw;

sub req {
    my (@jstr) = @_;
    my $req = provider::req(@jstr);
    # Provider-specific options
    $req->{provider} = {only => [split m/ +/m, $::ORIG_ENV{OPENROUTER_PROVIDER}]}
        if length($::ORIG_ENV{OPENROUTER_PROVIDER})//"";
    return $req;
}


package provider::nvidia;

use strict; use warnings;
use base qw(provider);

*raw = *provider::raw;

sub req {
    my (@jstr) = @_;
    my $req = provider::req(@jstr);
    $req->{chat_template_kwargs} = {"enable_thinking" => $Types::Serialiser::true};
    $req->{model} //= 'nvidia/nemotron-3.5-lightning-30b-a3b';
    return $req;
}

package provider::cerebras;

use strict; use warnings;
use base qw(provider);

*raw = *provider::raw;

sub req {
    my (@jstr) = @_;
    my $req = provider::req(@jstr);
    delete $req->{min_p};
    delete $req->{top_k};
    $req->{model} //= 'gpt-oss-120b';
    return $req;
}

package provider::lemonade;

use strict; use warnings;
use base qw(provider);

*req = *provider::req;
*raw = *provider::raw;


package provider::local;

use strict; use warnings;
use base qw(provider);

*req = *provider::req;
*raw = *provider::raw;


package prompt;

package prompt::default;

BEGIN {
    no warnings 'once';
    #*prompt::default::prompt = *{prompt::coder::prompt};
}

package prompt::coder;

sub prompt {
    my (%o) = @_;
    my %exclude = map {($_ => 1)} @{$o{exclude} // []};
    my $list = "\n\n**TOOLS**\n\n";
    $list .= "You can run tools. To call a tool, write its block exactly as shown below, starting at the\n";
    $list .= "beginning of a line and outside of your thinking. You may call several tools in one answer,\n";
    $list .= "they run in order. Then stop: the results are sent to you in the next message.\n";
    $list .= "\n\nTOOLS SYNTAX, for tool 'TOOL':\n\n";
    $list .= "```\n///TOOL_{HEX}+{T1}+{T2}\n{{path}}\n{T1}[<size of substituted {{path}}>]\n{{content}}\n{T2}[<size of substituted {{content}}>]\nTOOL_{HEX}\n```\nWhere {{path}}, {{content}} is substituted by the LLM\n";
    $list .= "TOOL results: [<TOOL_{HEX}> RESULT_d170\n{{result}}\nRESULT_d170]\n";
    $list .= "TOOL errors: [<TOOL_{HEX}> ERROR_9a78\n{{error}}\nERROR_9a78]\n";
    $list .= "\n\nLIST OF TOOLS:\n\n";
    $list .= join("\n\n", map {
        "name: $_\n".
        "tool: ```\n$tools::TOOLS->{$_}{syntax}\n```\n".
        "description: $tools::TOOLS->{$_}{description}\n".
        "properties:\n"._kv_print($tools::TOOLS->{$_}{properties}, 1).
        ($tools::TOOLS->{$_}{example} ? "example: ```\n$tools::TOOLS->{$_}{example}```\n" : "")
    } grep {!$exclude{$_}} sort keys %{$tools::TOOLS});
    $list .= "\n";
    log::info("TOOLS SECTION>>$list<<");
    return $list;
}

sub _kv_print {
    my ($h, $i) = @_;
    $i //= 0;
    my $s = "";
    foreach my $k (sort keys %{$h//{}}){
        if(ref($h->{$k}) eq 'HASH'){
            $s .= (" "x$i)."$k:\n"._kv_print($h->{$k}, $i+1);
        } else {
            $s .= (" "x$i)."$k: $h->{$k}\n";
        }
    }
    return $s;
}

package tools;

# Define available tools for the AI system prompt
our $TOOLS;
our $TOOLS_RX;

BEGIN {
    $tools::TOOLS = {
    bash => {
        description => "execute a bash script",
        syntax => "///BASH_7c48+EO_dfd7\n{{code}}\nEO_dfd7[LENGTH({{code}})]\nBASH_7c48",
        properties  => {
            "code" => {type => "string", description => "The bash code to execute"},
        },
        required => ["code"],
        example => <<EOb
///BASH_7c48+EO_dfd7
pwd
ls -la
EO_dfd7[10]
BASH_7c48
EOb
    },
    perl => {
        description => "execute a perl script",
        syntax => "///PERL_d8d2+EO_929b\n{{code}}\nEO_929b[LENGTH({{code}})]\nPERL_d8d2",
        properties  => {
            "code" => {type => "string", description => "The perl code to execute"},
        },
        required => ["code"],
    },
    read => {
        description => "read a file contents",
        syntax => "///READ_c5a3+EO_d0f1\n{{path}}\nEO_d0f1[LENGTH({{path}})]\nREAD_c5a3",
        properties  => {
            "path" => {type => "string", description => "The path to the file"},
        },
        required => ["path"],
    },
    write => {
        description => "write or overwrite a file",
        syntax => "///WRITE_edf5+EO_d068+EO_ecde\n{{path}}\nEO_d068[LENGTH({{path}})]\n{{content}}\nEO_ecde[LENGTH({{content}})]\nWRITE_edf5",
        properties  => {
            "path"    => {type => "string", description => "The path to the file"},
            "content" => {type => "string", description => "The raw text content to write"},
        },
        required => ["path", "content"],
        example => <<EOb
///WRITE_edf5+EO_d068+EO_ecde
perl_program.pl
EO_d068[15]
#!/usr/bin/perl
print "Hello, World!\\n";
EO_ecde[39]
WRITE_edf5
EOb
    },
    grep => {
        description => "search file with a pattern using grep unix tool",
        syntax => "///GREP_6629+EO_a575+EO_aada\n{{path}}\nEO_a575[LENGTH({{path}})]\n{{regex}}\nEO_aada[LENGTH({{regex}})]\nGREP_6629",
        properties  => {
            "path"  => {type => "string", description => "The file path or directory to scan"},
            "regex" => {type => "string", description => "The grep pattern"},
        },
        required => ["path", "regex"],
    },
    lines => {
        description => "read a file with line numbers, all of it or a range of lines like 10-40. Use this before 'edit'",
        syntax => "///LINES_7b06+EO_3fd1+EO_88ce\n{{path}}\nEO_3fd1[LENGTH({{path}})]\n{{range}}\nEO_88ce[LENGTH({{range}})]\nLINES_7b06",
        properties  => {
            "path"  => {type => "string", description => "The path to the file"},
            "range" => {type => "string", description => "first-last line number, a single line number, or empty for the whole file"},
        },
        required => ["path", "range"],
    },
    replace => {
        description => "replace a piece of text in a file. The old text must be in the file exactly once, with the same whitespace: include enough lines to make it unique",
        syntax => "///REPLACE_91c4+EO_5a0e+EO_c2b7+EO_f61d\n{{path}}\nEO_5a0e[LENGTH({{path}})]\n{{old}}\nEO_c2b7[LENGTH({{old}})]\n{{new}}\nEO_f61d[LENGTH({{new}})]\nREPLACE_91c4",
        properties  => {
            "path" => {type => "string", description => "The path to the file"},
            "old"  => {type => "string", description => "The exact text to replace"},
            "new"  => {type => "string", description => "The text to put there, empty to remove the old text"},
        },
        required => ["path", "old", "new"],
        example => <<EOb
///REPLACE_91c4+EO_5a0e+EO_c2b7+EO_f61d
perl_program.pl
EO_5a0e
print "Hello, World!\\n";
EO_c2b7
print "Hello, Perl!\\n";
EO_f61d
REPLACE_91c4
EOb
    },
    edit => {
        description => "edit a file with an ed script. Commands, one per line: Na (append after line N), Ni (insert before line N), N,Mc (change lines N to M), each followed by the new lines and a line with only a dot; N,Md (delete); N,Ms/regex/replacement/g (substitute). An address is a line number, \$ for the last line, or /regex/ for the first matching line. Line numbers are those after the previous commands: edit from the bottom of the file to the top. Nothing is written when a command fails",
        syntax => "///EDIT_b3e1+EO_0c7a+EO_d95f\n{{path}}\nEO_0c7a[LENGTH({{path}})]\n{{script}}\nEO_d95f[LENGTH({{script}})]\nEDIT_b3e1",
        properties  => {
            "path"   => {type => "string", description => "The path to the file"},
            "script" => {type => "string", description => "The ed commands"},
        },
        required => ["path", "script"],
        example => <<EOb
///EDIT_b3e1+EO_0c7a+EO_d95f
perl_program.pl
EO_0c7a
12,14c
my \$name = shift // "World";
print "Hello, \$name!\\n";
.
3d
1a
use strict;
.
EO_d95f
EDIT_b3e1
EOb
    },
    delete => {
        description => "delete a file or an empty directory",
        syntax => "///DELETE_5d2a+EO_e410\n{{path}}\nEO_e410[LENGTH({{path}})]\nDELETE_5d2a",
        properties  => {
            "path" => {type => "string", description => "The path to delete"},
        },
        required => ["path"],
    },
    move => {
        description => "move or rename a file or directory, the destination must not exist",
        syntax => "///MOVE_c7f0+EO_1b9d+EO_7e23\n{{from}}\nEO_1b9d[LENGTH({{from}})]\n{{to}}\nEO_7e23[LENGTH({{to}})]\nMOVE_c7f0",
        properties  => {
            "from" => {type => "string", description => "The current path"},
            "to"   => {type => "string", description => "The new path"},
        },
        required => ["from", "to"],
    },
    mkdir => {
        description => "create a directory, with its parents",
        syntax => "///MKDIR_2e9b+EO_ab54\n{{path}}\nEO_ab54[LENGTH({{path}})]\nMKDIR_2e9b",
        properties  => {
            "path" => {type => "string", description => "The directory to create"},
        },
        required => ["path"],
    },
    agent => {
        description => "give a task to a sub-agent and get its final answer. It has the same tools but knows nothing of this conversation: put everything it needs in the task (goal, paths, what to report). Several agent calls in one answer work in parallel, use that for independent tasks like exploring different parts of a project",
        syntax => "///AGENT_f2a8+EO_9d31\n{{task}}\nEO_9d31[LENGTH({{task}})]\nAGENT_f2a8",
        properties  => {
            "task" => {type => "string", description => "The complete, self-contained task"},
        },
        required => ["task"],
    },
    list => {
        description => "list a directory: type (d, f, l), size and name of every entry",
        syntax => "///LIST_a41d+EO_6c08\n{{path}}\nEO_6c08[LENGTH({{path}})]\nLIST_a41d",
        properties  => {
            "path" => {type => "string", description => "The directory, . for the current one"},
        },
        required => ["path"],
    },
    };

    # derive from the syntax: the tag (BASH_7c48, also the name of the sub that
    # implements the tool) and the sentinels that close each argument
    my @tags;
    foreach my $t (values %{$tools::TOOLS}){
        my ($header) = split m/\n/, $t->{syntax};
        my ($tag, @sentinels) = split m/\+/, $header =~ s/^\/\/\///r;
        $t->{tag}       = $tag;
        $t->{sentinels} = \@sentinels;
        push @tags, quotemeta($tag);
    }
    # a tool call starts with its header line: $1 the tag, $2 the sentinels
    $TOOLS_RX = '^[ \t]*///('.join('|', sort @tags).')((?:\+\w+)*)[ \t]*\n';
}

sub rx {
    $TOOLS_RX;
}

our $ASYNC; # true: _run hands back a job for the event loop instead of waiting

# Run a worker in a fork, give back its output. Dies with the reason and the
# output so far when it did not end well. Options: cleanup (a sub, called when
# the child is gone), exit_ok (exit codes besides 0 that are fine).
# With $ASYNC nothing is started: the job comes back, see execute_tool_async.
sub _run {
    my ($worker_sub, %o) = @_;
    my $timeout = $::ORIG_ENV{AI_TOOL_TIMEOUT} // 120;
    my $finish = sub {
        my ($out, $exit, $sig, $why) = @_;
        $o{cleanup}->() if $o{cleanup};
        return $out unless $why or $sig or ($exit and !grep {$exit == $_} @{$o{exit_ok} // []});
        $out =~ s/\n\z//;
        die "$why, output: $out\n" if $why;
        die "killed by signal $sig, output: $out\n" if $sig;
        die "exit code: $exit, output: $out\n";
    };
    return bless({worker => $worker_sub, timeout => $timeout, finish => $finish}, 'tools::job')
        if $ASYNC;
    return &{$finish}(utils::fork_run($worker_sub, timeout => $timeout));
}

# agent: a sub-agent works on the task, see package agent. (Several calls in
# one answer are started together by handle_llm_response, this is one alone.)
sub agent_f2a8 {
    my ($t_args) = @_;
    my $task = $t_args->[0] // '';
    die "no task\n" unless $task =~ m/\S/;
    my $a = agent::launch($task);
    agent::wait($a);
    my ($result, $err) = ai::agent_result($a);
    die(($err =~ s/^\[ERROR\] //r)."\n") if defined $err;
    return $result;
}

# bash: the script goes to a temp file, a forked child exec()s bash on it
sub bash_7c48 {
    my ($t_args) = @_;
    utils::load_cpan("File::Temp");
    my ($fh, $fn) = File::Temp::tempfile("aicli_bash_XXXXXXXX", TMPDIR => 1);
    print {$fh} $t_args->[0] // '';
    if(!close($fh)){
        my $err = $!;
        unlink $fn;
        die "failed to write to temp file: $err\n";
    }
    return _run(sub {exec {'bash'} 'bash', $fn or die "cannot exec bash: $!\n"},
        cleanup => sub {unlink $fn});
}

# code of the LLM gets its own package, and none of our lexicals
sub _eval_perl {
    package aicli::tool;
    no strict;
    no warnings;
    eval $_[0];
    die $@ if $@;
    return;
}

# perl: eval in a forked child. Full "freedom" by default: it is a sub-process,
# and dockerized. With AI_PERL_SAFE the code runs in a Safe compartment: "1"
# for the default opcode set plus :base_io (print, but no open), or a list of
# extra opcodes/tags to permit.
sub perl_d8d2 {
    my ($t_args) = @_;
    my $code = $t_args->[0];
    die "need an actual perl program, size=0\n" unless length($code // "");
    my $safe = $::ORIG_ENV{AI_PERL_SAFE};
    utils::load_cpan("Safe") if $safe;
    return _run(sub {
        if($safe){
            my $cpt = Safe->new();
            # the default opcode set, and I/O on the handles that are open
            $cpt->permit(':base_io');
            $cpt->permit(grep {length} split m/[\s,]+/, $safe) if $safe ne '1';
            $cpt->share_from('main', ['*STDOUT', '*STDERR']);
            $cpt->reval($code);
            die $@ if $@;
            return;
        }
        # exit() must not run the END blocks of the chat: _exit instead
        no warnings 'once';
        *CORE::GLOBAL::exit = sub {
            STDOUT->flush();
            STDERR->flush();
            POSIX::_exit($_[0] // 0);
        };
        _eval_perl($code);
    });
}

sub read_c5a3 {
    my ($t_args) = @_;
    return _slurp(utils::trim($t_args->[0] // ''));
}

sub write_edf5 {
    my ($t_args) = @_;
    my $path = utils::trim($t_args->[0] // '');
    log::info("WRITE: $path");
    open(my $fh, '>', $path)
        or die "Cannot write to $path: $!\n";
    print {$fh} $t_args->[1] // '';
    close($fh)
        or die "problem running tool 'write' for $path: $!\n";
    return "[OK] written to $path";
}

# The file tools below are plain perl, in the chat process: no fork, no shell.

sub _slurp {
    my ($file) = @_;
    die "is a directory: $file\n" if -d $file;
    open(my $fh, '<', $file)
        or die "cannot read $file: $!\n";
    local $/;
    my $content = <$fh>;
    close($fh);
    return $content // "";
}

# write through a temp file and rename: all of it or nothing, mode kept
sub _spew {
    my ($file, $content) = @_;
    my $tmp  = "$file.aicli.$$";
    my $mode = (stat($file))[2];
    open(my $fh, '>', $tmp)
        or die "cannot write $tmp: $!\n";
    print {$fh} $content;
    if(!close($fh)){
        my $err = $!;
        unlink $tmp;
        die "cannot write $tmp: $err\n";
    }
    chmod($mode & 07777, $tmp) if defined $mode;
    if(!rename($tmp, $file)){
        my $err = $!;
        unlink $tmp;
        die "cannot replace $file: $err\n";
    }
    return;
}

sub lines_7b06 {
    my ($t_args) = @_;
    my $file  = utils::trim($t_args->[0] // '');
    my $range = utils::trim($t_args->[1] // '');
    my @lines = split m/\n/, _slurp($file), -1;
    pop @lines if @lines and $lines[-1] eq '';
    my ($from, $to) = (1, scalar(@lines));
    if($range =~ m/^(\d+)\s*(?:[-,]\s*(\d+|\$)?)?$/){
        $from = $1;
        $to   = (defined $2 and $2 ne '$') ? $2 : ($range =~ m/[-,]/ ? scalar(@lines) : $1);
    } elsif(length($range)){
        die "bad range '$range', use first-last\n";
    }
    $from = 1 if $from < 1;
    $to = @lines if $to > @lines;
    die "no such lines, $file has ".scalar(@lines)." lines\n" if $from > $to and @lines;
    return join('', map {"$_\t$lines[$_ - 1]\n"} $from .. $to);
}

sub replace_91c4 {
    my ($t_args) = @_;
    my $file = utils::trim($t_args->[0] // '');
    my ($old, $new) = ($t_args->[1] // '', $t_args->[2] // '');
    die "the old text is empty\n" unless length($old);
    my $content = _slurp($file);
    my $count = () = $content =~ m/\Q$old\E/g;
    die "the old text is not in $file, mind the exact whitespace\n" unless $count;
    die "the old text is $count times in $file, add lines around it to make it unique\n" if $count > 1;
    my $at = index($content, $old);
    substr($content, $at, length($old)) = $new;
    _spew($file, $content);
    return "[OK] replaced in $file at line ".(1 + (substr($content, 0, $at) =~ tr/\n//));
}

# address of an ed command -> line number
sub _ed_addr {
    my ($addr, $lines, $after) = @_;
    return scalar(@$lines) if $addr eq '$';
    return $addr + 0 if $addr =~ m/^\d+$/;
    my ($re) = $addr =~ m{^/(.*)/$}s;
    my $rx = eval {qr/$re/}
        or die "bad regex in address $addr\n";
    foreach my $i (($after // 0) .. $#$lines){
        return $i + 1 if $lines->[$i] =~ $rx;
    }
    die "no line matches $addr\n";
}

# apply an ed script (a, i, c, d, s) to a text, returns the new text
sub ed_apply {
    my ($text, $script) = @_;
    my @lines = split m/\n/, $text, -1;
    my $eol = (@lines and $lines[-1] eq '') ? 1 : 0;
    pop @lines if $eol;
    $eol = 1 unless length($text);
    my @cmds = split m/\n/, $script // '', -1;
    my $n = 0;
    my $addr_rx = qr{\d+|\$|/(?:[^/\\]|\\.)*/};
    while(@cmds){
        my $c = shift @cmds;
        next if $c =~ m/^\s*$/ or $c =~ m/^\s*[wq]\s*$/;
        $n++;
        my ($a1, $a2, $op, $rest) = $c =~ m{^\s*(?:($addr_rx)(?:,($addr_rx))?)?\s*([acdis])(.*)$}s
            or die "command $n: cannot parse '$c'\n";
        eval {
            die "needs a line address\n" unless defined $a1;
            my $from = _ed_addr($a1, \@lines);
            my $to   = defined $a2 ? _ed_addr($a2, \@lines, $from) : $from;
            die "line $from is after line $to\n" if $from > $to;
            die "no line $to, the file has ".scalar(@lines)." lines\n" if $to > @lines;
            die "no line 0\n" if $from < 1 and $op ne 'a';
            if($op =~ m/[aic]/){
                die "text follows on the next lines, not after the command\n" if $rest =~ m/\S/;
                my @t;
                my $closed = 0;
                while(@cmds){
                    my $l = shift @cmds;
                    $closed = 1, last if $l eq '.';
                    push @t, $l;
                }
                die "the text is not closed by a line with only a dot\n" unless $closed;
                splice(@lines, $from, 0, @t)                    if $op eq 'a';
                splice(@lines, $from - 1, 0, @t)                if $op eq 'i';
                splice(@lines, $from - 1, $to - $from + 1, @t)  if $op eq 'c';
            } elsif($op eq 'd'){
                die "nothing may follow d\n" if $rest =~ m/\S/;
                splice(@lines, $from - 1, $to - $from + 1);
            } else {
                my $d = quotemeta(substr($rest, 0, 1));
                my ($re, $repl, $flags) = $rest =~ m/^$d((?:[^\\]|\\.)*?)$d((?:[^\\]|\\.)*?)(?:$d([gi]*))?\s*$/s
                    or die "use s/regex/replacement/\n";
                my $rx = eval {($flags // '') =~ m/i/ ? qr/$re/i : qr/$re/}
                    or die "bad regex /$re/\n";
                $repl =~ s/\\($d)/$1/g;
                my $sub = sub {
                    my @g = map {substr($_[0], $-[$_], $+[$_] - $-[$_])} grep {defined $-[$_]} 0 .. $#-;
                    # \1 or $1: group, &: the match, \& and \\: literal
                    return $repl =~ s{\\([\\&])|\\(\d)|\$(\d)|(&)}{
                        defined $1 ? $1 : defined $4 ? $g[0] : ($g[$2 // $3] // '')
                    }ger;
                };
                my $hits = 0;
                foreach my $l (@lines[$from - 1 .. $to - 1]){
                    $hits += ($flags // '') =~ m/g/
                        ? ($l =~ s/$rx/$sub->($l)/ge)
                        : ($l =~ s/$rx/$sub->($l)/e);
                }
                die "no match for /$re/ in line".($from == $to ? " $from" : "s $from-$to")."\n" unless $hits;
            }
            1;
        } or die "command $n ($c): $@";
    }
    die "no commands\n" unless $n;
    return join("\n", @lines).(($eol and @lines) ? "\n" : "");
}

sub edit_b3e1 {
    my ($t_args) = @_;
    my $file = utils::trim($t_args->[0] // '');
    my $old  = _slurp($file);
    my $new  = ed_apply($old, $t_args->[1]);
    return "[OK] no change in $file" if $new eq $old;
    _spew($file, $new);
    return "[OK] edited $file: ".($old =~ tr/\n//)." -> ".($new =~ tr/\n//)." lines";
}

sub delete_5d2a {
    my ($t_args) = @_;
    my $path = utils::trim($t_args->[0] // '');
    die "no path\n" unless length($path);
    if(-d $path and !-l $path){
        rmdir($path)
            or die "cannot remove directory $path: $!\n";
        return "[OK] removed directory $path";
    }
    die "no such file: $path\n" unless -e $path or -l $path;
    unlink($path)
        or die "cannot delete $path: $!\n";
    return "[OK] deleted $path";
}

sub move_c7f0 {
    my ($t_args) = @_;
    my $from = utils::trim($t_args->[0] // '');
    my $to   = utils::trim($t_args->[1] // '');
    die "need two paths\n" unless length($from) and length($to);
    die "no such file: $from\n" unless -e $from or -l $from;
    $to = "$to/".($from =~ s{.*/}{}r) if -d $to;
    die "$to exists already\n" if -e $to or -l $to;
    if(!rename($from, $to)){
        # another filesystem
        utils::load_cpan("File::Copy");
        File::Copy::move($from, $to)
            or die "cannot move $from to $to: $!\n";
    }
    return "[OK] moved $from to $to";
}

sub mkdir_2e9b {
    my ($t_args) = @_;
    my $path = utils::trim($t_args->[0] // '');
    die "no path\n" unless length($path);
    return "[OK] $path exists already" if -d $path;
    utils::load_cpan("File::Path");
    File::Path::make_path($path, {error => \my $err});
    die "cannot create $path: ".join(", ", map {values %$_} @$err)."\n" if @$err;
    return "[OK] created $path";
}

sub list_a41d {
    my ($t_args) = @_;
    my $path = utils::trim($t_args->[0] // '');
    $path = '.' unless length($path);
    opendir(my $dh, $path)
        or die "cannot list $path: $!\n";
    my @names = sort grep {$_ ne '.' and $_ ne '..'} readdir($dh);
    closedir($dh);
    return join('', map {
        my $f = "$path/$_";
        my $type = -l $f ? 'l' : -d _ ? 'd' : 'f';
        sprintf("%s %10s %s%s\n", $type, $type eq 'd' ? '-' : (lstat($f))[7] // '?', $_, $type eq 'd' ? '/' : '');
    } @names);
}

# grep: a forked child exec()s grep, no shell involved
sub grep_6629 {
    my ($t_args) = @_;
    my $path    = utils::trim($t_args->[0] // '');
    my $pattern = $t_args->[1];
    die "not enough properties\n" unless length($path) and length($pattern // "");
    return _run(sub {
        exec {'grep'} 'grep', '-rn', '-e', $pattern, '--', $path
            or die "cannot exec grep: $!\n";
    }, exit_ok => [1]); # 1: no match
}


BEGIN {
package colors;

our $red_color     = "\033[0;31m";
our $green_color   = "\033[0;32m";
our $yellow_color1 = "\033[0;33m";
our $blue_color1   = "\033[0;34m";
our $blue_color2   = "\033[38;5;25;1m";
our $blue_color3   = "\033[38;5;13;1m";
our $magenta_color = "\033[0;35m";
our $cyan_color    = "\033[0;36m";
our $white_color   = "\033[0;37m";
our $reset_color   = "\033[0m";
}

1;
