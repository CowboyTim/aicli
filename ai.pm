package ai;

use strict; use warnings;

use utils;
use tui;
use md;

use Cwd ();
use Encode ();
use Errno;
use JSON::XS ();
use Time::HiRes ();

BEGIN {
    # canonical: the same data is always the same bytes, in requests and files
    $::JSON //= JSON::XS->new->utf8->canonical->allow_blessed->allow_unknown->allow_nonref->convert_blessed;
}

# Variables/Handles
our ($api_key, $AI_ENDPOINT_URL, $SESSION_MODEL, $provider_name);
our ($AI_SESSION_DIR, $HISTORY_FILE, $PROMPT_FILE, $STATUS_FILE, $BASE_DIR, $AI_PROMPT_TEMPLATE, $AI_PROMPT_TEMPLATE_FILE, $AI_SESSION, $SESSIONS_DIR, $AI_PROVIDER, $AI_URL);
our $cmds;
our @MODELS;
our $TUI = tui->new(enabled => 0); # the status line, switched on in chat_loop
our $BUSY = 0;      # a completion/tool turn is running: ctrl-C aborts the turn only
our $MAIN_PID = $$;
our %AUTO_SESSION;    # sessions this process made up a name for
our $WORKSPACE;       # the directory the file tools are confined to, undef: no limit
our @WORKSPACE_ALLOW; # more directories they may use

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
    'flm' => {
        url   => 'http://localhost:8001', # FastFlowLM, the NPU: one request at a time
        local => 1,
    },
    'openai' => {
        url => 'https://api.openai.com',
        key_prefix => 'sk-',
    },
    'anthropic' => {
        url => 'https://api.anthropic.com', # its own message format, see provider::anthropic
        key_prefix => 'sk-ant-',
    },
);

# tool processes never get to see the API key
push @utils::CHILD_INIT, sub {$api_key = undef};
# and they are confined to the workspace by the kernel, where it can do that
push @utils::CHILD_INIT, \&sandbox_child;

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
    $AI_SESSION = $::ORIG_ENV{AI_SESSION};
    # --continue: go on where this directory left off
    $AI_SESSION = last_session()
        if !length($AI_SESSION // '') and $::ORIG_ENV{AI_CONTINUE};
    if(!length($AI_SESSION // '')){
        $AI_SESSION = "session-".new_session_id();
        $AUTO_SESSION{$AI_SESSION} = 1; # ours: removed at the end when nothing was said
    }
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
            # the longest prefix first: 'sk-ant-' and 'sk-or-' before 'sk-'
            for my $name (sort {length($PROVIDERS{$b}{key_prefix} // '') <=> length($PROVIDERS{$a}{key_prefix} // '') || $a cmp $b} keys %PROVIDERS) {
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
    $AI_URL = "$AI_ENDPOINT_URL/v1/messages" if $AI_PROVIDER eq 'anthropic';

    set_workspace($::ORIG_ENV{AI_WORKSPACE});
    tidy_sessions($AI_SESSION);
    init_session($AI_SESSION);
    use_session($AI_SESSION);
    return;
}

# Confine the file tools to a directory: the given one, the current directory
# by default, "none" for no limit. AI_WORKSPACE_ALLOW adds directories.
# Returns the workspace, undef for none.
sub set_workspace {
    my ($dir) = @_;
    if(($dir // '') =~ m/^(?:none|off|no)$/i){
        ($WORKSPACE, @WORKSPACE_ALLOW) = (undef);
        return;
    }
    $dir = Cwd::cwd() unless length($dir // '');
    die "workspace is not a directory: $dir\n" unless -d $dir;
    $WORKSPACE = tools::_resolve($dir);
    @WORKSPACE_ALLOW = map {tools::_resolve($_)} grep {length and -d $_}
        split m/[\s,:]+/, $::ORIG_ENV{AI_WORKSPACE_ALLOW} // '';
    return $WORKSPACE;
}

sub tmpdir {
    return $::ORIG_ENV{TMPDIR} // $ENV{TMPDIR} // '/tmp';
}

# What the forked tools (bash, perl, grep) may do to the filesystem, for
# sandbox::confine: (write => [...]) and, with AI_SANDBOX_READ, (read => [...]).
# Empty when they are not confined: AI_SANDBOX=off, or no workspace.
#   write: the workspace, AI_WORKSPACE_ALLOW, the temp directory, a few
#          devices, and what AI_SANDBOX_WRITE names (/dev/ttyACM0, /sys, ...)
#   read:  everything, unless AI_SANDBOX_READ is set: then only the system
#          directories, the places above, and what it names
sub sandbox_policy {
    return if lc($::ORIG_ENV{AI_SANDBOX} // 'auto') =~ m/^(?:off|no|none|0)$/;
    return if !defined $WORKSPACE or $WORKSPACE eq '/';
    my $list = sub {grep {length} split m/[\s,:]+/, $_[0] // ''};
    my @write = ($WORKSPACE, @WORKSPACE_ALLOW, tmpdir(),
        qw(/dev/null /dev/zero /dev/full /dev/tty /dev/ptmx /dev/pts /dev/shm),
        &{$list}($::ORIG_ENV{AI_SANDBOX_WRITE}));
    my %p = (write => \@write);
    if(length($::ORIG_ENV{AI_SANDBOX_READ} // '')){
        $p{read} = [qw(/usr /bin /sbin /lib /lib32 /lib64 /libx32 /etc /opt /proc /sys /dev /run),
            grep {$_ ne 'system'} &{$list}($::ORIG_ENV{AI_SANDBOX_READ})];
    }
    return %p;
}

# is the sandbox there, and wanted: 'on', 'off', or 'unavailable'
sub sandbox_state {
    my %p = sandbox_policy()
        or return 'off';
    return sandbox::abi() ? 'on' : 'unavailable';
}

# in the forked child of a tool, before the tool runs
sub sandbox_child {
    my %p = sandbox_policy()
        or return;
    return if sandbox::confine(%p);
    # the kernel cannot: fine, unless it was asked for
    die "no sandbox: this kernel has no landlock (AI_SANDBOX=".$::ORIG_ENV{AI_SANDBOX}.")\n"
        if lc($::ORIG_ENV{AI_SANDBOX} // 'auto') =~ m/^(?:on|yes|1|require)$/;
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
    my $old_history = $HISTORY_FILE;
    $AI_SESSION     = $session;
    $AI_SESSION_DIR = "$SESSIONS_DIR/$AI_SESSION";
    $HISTORY_FILE   = "$AI_SESSION_DIR/history";
    # the input history belongs to the session: save the one, load the other
    if($::T and defined $old_history and $old_history ne $HISTORY_FILE){
        eval {
            $::T->write_history($old_history) if -d ($old_history =~ s{/[^/]+\z}{}r);
            $::T->clear_history();
            $::T->ReadHistory($HISTORY_FILE) if -e $HISTORY_FILE;
            1;
        } or log::info("input history not switched: $@");
    }
    $PROMPT_FILE    = "$AI_SESSION_DIR/prompt";
    $STATUS_FILE    = "$AI_SESSION_DIR/chat";
    $SESSION_MODEL  = read_session_model() || $::ORIG_ENV{AI_MODEL};
    # where it is used, for --continue
    eval {spew("$AI_SESSION_DIR/cwd", Cwd::cwd()."\n")} if -d $AI_SESSION_DIR;
    # the footer: the numbers of this session, not the speed of a request of another
    $TUI->info($_ => undef) for qw(speed cache);
    status_info();
    return;
}

# the session that was last used in a directory (default: this one), if any
sub last_session {
    my ($dir) = @_;
    $dir //= Cwd::cwd();
    my ($best, $best_t);
    foreach my $s (@{get_sessions()}){
        my $cwd = slurp("$SESSIONS_DIR/$s/cwd") // next;
        chomp $cwd;
        next unless $cwd eq $dir;
        my $t = (stat("$SESSIONS_DIR/$s/chat"))[9] // next;
        ($best, $best_t) = ($s, $t) if !defined $best_t or $t > $best_t;
    }
    return $best;
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
    return "[ERROR] no tool named '$c->{tool}', nothing was executed." unless $c->{t};
    if($c->{native}){
        # a call of the API: say what the arguments are, not the text syntax
        my %required = map {($_ => 1)} @{$c->{t}{required} // []};
        my $args = join(', ', map {"\"$_\": string".($required{$_} ? ' (required)' : '')} tools::arg_names($c->{t}));
        return "[ERROR] bad arguments for '".lc($c->{tool})."', nothing was executed. The arguments are a JSON object: {$args}";
    }
    return "[ERROR] malformed tool call for '$c->{tool}', nothing was executed. Expected syntax:\n$c->{t}{syntax}";
}

# Tool calls go through the API (native) unless AI_TOOL_CALLS=text, or the
# request is a raw prompt (AI_RAW, the client writes the template) or the API
# is Anthropic (its own format, not used yet). Then the tools are sent in the
# request and the model's calls come back in tool_calls.
our $ONE_SHOT = 0; # set by one_shot(): -p
our $IN_AGENT = 0; # set while a sub-agent builds its request
# the calls the server made itself, from the stream: each has an id (its result
# refers to it), the arguments are complete
sub stream_tool_calls {
    my ($st) = @_;
    my $n = 0;
    return [map {
        $_->{id} //= sprintf('call_%d_%d', $$, ++$n);
        $_->{arguments} //= '';
        $_;
    } grep {$_ and length($_->{name} // '')} @{$st->{tool_calls} // []}];
}

# the provider in use (undef before the setup)
sub provider_is {
    my ($name) = @_;
    return defined $AI_PROVIDER && $AI_PROVIDER eq $name;
}

# The answer length limit when AI_TOKENS is not set. FastFlowLM answers for
# the NPU: a model that loops would stream for minutes at 100000, so it gets
# 8192; the other providers keep 100000.
sub default_tokens {
    return provider_is('flm') ? 8192 : 100_000;
}

# How many sub-agents work at once. FastFlowLM locks the NPU for one request
# at a time, so it defaults to one.
sub max_agents {
    return $::ORIG_ENV{AI_MAX_AGENTS} // 4;
}

sub native_calls {
    return 0 if $::ORIG_ENV{AI_RAW};
    return 0 if ($::ORIG_ENV{AI_TOOL_CALLS} // 'native') ne 'native';
    return 0 if defined $AI_PROVIDER and $AI_PROVIDER eq 'anthropic';
    return 1;
}

# a call the server sent (name and JSON arguments) as the call record the
# tools run from; the tool is undef when there is no such tool
sub native_call {
    my ($c) = @_;
    my $name = $c->{name} // '';
    my $k    = lc $name;
    my $t    = $tools::TOOLS->{$k};
    my $args = $t ? tools::native_args($k, $c->{arguments}) : undef;
    return {
        id   => $c->{id},
        tool => uc($name),
        k    => $k,
        t    => $t,
        args => $args,
        native => 1,
    };
}

# what the model gets to see of a tool run
sub tool_response {
    my ($tool, $result, $had_error) = @_;
    return "[$tool ERROR_9a78\n$had_error\nERROR_9a78]" if $had_error;
    return "[$tool RESULT_d170\n".($result // '')."\nRESULT_d170]";
}

sub handle_llm_response {
    my ($resp, $printer_sub, $native) = @_;
    $native //= []; # the calls the server made (native), else the ones in the text
    return (0, 0, []) unless defined $resp and ref($resp) eq 'SCALAR' and (length($$resp // "") or @$native);
    log::info("handling>>".($$resp // '')."<<");
    # with a printer of the caller everything is handed to it in full
    my $brief = (!$printer_sub and tool_display() eq 'brief') ? 1 : 0;
    my $say = sub {
        $TUI->clear();
        print $_[0];
    };
    $printer_sub //= $say;

    # tools work with bytes, and never run from within a thinking block
    my $msg = to_bytes(strip_thinking($$resp // ''));
    log::info("MSG THINK STRIPPED>>$msg<<");
    my (@rt, @agents);
    my $announce = sub {
        my ($c) = @_;
        return &{$printer_sub}("${colors::yellow_color1}\[TOOL $c->{tool}\(...))\]${colors::reset_color}\n")
            unless $brief;
        &{$say}("${colors::yellow_color1}\x{e2}\x{97}\x{8f} $c->{k}${colors::reset_color} ".tool_summary($c)."\n");
    };
    my $answer = sub {
        my ($i, $c, $result, $had_error) = @_;
        my $tool_response = tool_response($c->{tool}, $result, $had_error);
        # a call of the server is answered with a tool message, as its API wants
        $rt[$i] = $c->{id}
            ? {role => 'tool', tool_call_id => $c->{id}, content => to_text($had_error // $result // '')}
            : {role => 'user', content => to_text($tool_response)};
        my $changed = scalar(@tools::CHANGES);
        if(!$brief){
            &{$printer_sub}("${colors::green_color}$tool_response${colors::reset_color}\n");
        } elsif($had_error){
            my $e = $had_error =~ s/^\[ERROR\] (?:problem running tool '\w+': )?//r;
            &{$say}($colors::red_color.clip_lines($e, $::ORIG_ENV{AI_TOOL_LINES} // 8, "  ").$colors::reset_color);
        } elsif(!$changed or !($::ORIG_ENV{AI_SHOW_DIFF} // 1)){
            # (a file change shows its diff instead)
            &{$say}($colors::green_color.clip_lines($result, $::ORIG_ENV{AI_TOOL_LINES} // 8, "  ").$colors::reset_color);
        }
        show_changes($printer_sub == $say ? $say : undef);
    };
    foreach my $c (@$native ? map {native_call($_)} @$native : parse_tool_calls($msg)){
        my $i = scalar(@rt);
        push @rt, undef;
        &{$announce}($c);
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
        @tools::CHANGES = (); # what the agents changed is in the undo journal
        foreach my $e (@agents){
            my ($i, $c, $a) = @$e;
            &{$say}("${colors::yellow_color1}\x{e2}\x{97}\x{8f} agent $a->{id}${colors::reset_color} answered\n") if $brief;
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
    return &{$cb}("", "[ERROR] tool '$tool' is not available here") unless tools::available($k);
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
    # a child process (worker), or whatever registers itself in the loop (start)
    my $start = $ret->{start} // sub {
        my ($done) = @_;
        loop::spawn($ret->{worker}, timeout => $ret->{timeout}, on_done => $done);
    };
    &{$start}(sub {
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
    return "", "[ERROR] tool '$tool' is not available here" unless tools::available($k);
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
        timings   => undef, # llama.cpp: how fast the prompt and the answer went
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
        # Anthropic Messages API events: the usage comes in two of them, as
        # input and output tokens, kept in the shape of the other APIs
        my $type = $decoded->{type} // '';
        if($type eq 'message_start' or $type eq 'message_delta' or $type eq 'content_block_delta'
            or $type eq 'message_stop' or $type eq 'content_block_start' or $type eq 'ping'){
            my $u = ref($decoded->{message}) eq 'HASH' ? $decoded->{message}{usage} : $decoded->{usage};
            if(ref($u) eq 'HASH'){
                my $cached = $u->{cache_read_input_tokens} // 0;
                $st->{anth_in}  = ($u->{input_tokens} // $st->{anth_in} // 0) + $cached + ($u->{cache_creation_input_tokens} // 0)
                    if defined $u->{input_tokens};
                $st->{anth_cached} = $cached if defined $u->{cache_read_input_tokens};
                $st->{anth_out} = $u->{output_tokens} if defined $u->{output_tokens};
                my ($in, $out) = ($st->{anth_in} // 0, $st->{anth_out} // 0);
                $st->{usage} = {prompt_tokens => $in, completion_tokens => $out, total_tokens => $in + $out,
                    prompt_tokens_details => {cached_tokens => $st->{anth_cached} // 0}};
            }
            if($type eq 'content_block_delta'){
                my $d = $decoded->{delta} // {};
                if(($d->{type} // '') eq 'thinking_delta' and defined $d->{thinking} and length $d->{thinking}){
                    $st->{reasoning} .= $d->{thinking};
                    &{$emit}('think', $d->{thinking});
                } elsif(defined $d->{text} and length $d->{text}){
                    &{$content}($d->{text});
                }
            }
            $st->{done} = 1 if $type eq 'message_stop';
            return;
        }
        $st->{usage} = $decoded->{usage} if ref($decoded->{usage}) eq 'HASH';
        $st->{timings} = $decoded->{timings} if ref($decoded->{timings}) eq 'HASH';
        if(my $e = $decoded->{error}){
            $st->{error} = $decoded;
            return;
        }
        my $msg_entry = ref($decoded->{choices}) eq 'ARRAY' ? ($decoded->{choices}[0] // {}) : {};
        my $d = $msg_entry->{delta} // $msg_entry->{message} // {};
        # tool calls the server parsed itself (OpenAI style): logged, and put
        # together by index, the arguments come in pieces
        if(ref($d->{tool_calls}) eq 'ARRAY'){
            for my $tc (@{$d->{tool_calls}}){
                next unless ref($tc) eq 'HASH';
                log::info("SERVER TOOL CALL DELTA: ".$::JSON->encode($tc));
                my $e = $st->{tool_calls}[$tc->{index} // 0] //= {};
                my $f = ref($tc->{function}) eq 'HASH' ? $tc->{function} : {};
                $e->{id}   //= $tc->{id};
                $e->{name} //= $f->{name};
                $e->{arguments} .= $f->{arguments} // '';
            }
        }
        $st->{finish_reason} = $msg_entry->{finish_reason} if defined $msg_entry->{finish_reason};
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
        if(my @calls = grep {defined} @{$st->{tool_calls} // []}){
            log::info("SERVER TOOL CALLS (finish_reason ".($st->{finish_reason} // "none")."): ".$::JSON->encode(\@calls));
        }
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
    my ($out, %o) = @_;
    my $out_arg = $out; # a printer that was given its output (a test, a pipe) gets no colors of the markdown
    $out //= sub {$TUI->clear(); print $_[0]};
    my $show_thinking = ($::ORIG_ENV{AI_SHOW_THINKING} // 1) ? 1 : 0;
    my ($last, $ends_nl) = ('', 1);
    # hide_tools: the tool call blocks in the answer are not shown, the tool
    # display says what runs. A line is held back until it is clear that it
    # does not start a tool call.
    my ($bol, $hold, $in_tool) = (1, '', undef);
    my $t_rx = tools::rx();
    my $visible = sub {
        my ($text) = @_;
        my $vis = '';
        $hold .= $text;
        while(length($hold)){
            my $nl = index($hold, "\n");
            if(defined $in_tool){
                last if $nl < 0;
                my $line = substr($hold, 0, $nl + 1, '');
                if($line =~ m/^\s*\Q$in_tool\E\s*$/){
                    ($in_tool, $bol) = (undef, 1);
                } elsif($line =~ m/$t_rx/){
                    $in_tool = $1; # the next call, the one before was not closed
                }
            } elsif($bol and $nl < 0){
                last if $hold =~ m{^[ \t]*(?:/{0,3}|///[\w+]*[ \t]*)$}; # may become a tool call
                $bol = 0;
            } elsif($bol){
                my $line = substr($hold, 0, $nl + 1, '');
                if($line =~ m/$t_rx/){
                    $in_tool = $1;
                } else {
                    $vis .= $line;
                }
            } elsif($nl < 0){
                $vis .= $hold;
                $hold = '';
            } else {
                $vis .= substr($hold, 0, $nl + 1, '');
                $bol = 1;
            }
        }
        return $vis;
    };
    # markdown is drawn for the terminal only: a pipe gets the text as it is
    my $md = (($::ORIG_ENV{AI_MARKDOWN} // ((-t STDOUT and !defined $out_arg) ? 1 : 0)) ? 1 : 0)
        ? md->new(base => $colors::green_color) : undef;
    my $p = {};
    my $show = sub {
        my ($kind, $text) = @_;
        if($md){
            if($kind eq 'text'){
                my $drawn = $md->feed($text);
                return unless length $drawn;
                if($last ne 'text'){
                    # the same spacing as below: a line of its own, a blank line after thinking
                    $drawn =~ s/\A\n+//;
                    return unless length $drawn;
                    &{$out}("\n") unless $ends_nl;
                    &{$out}("\n") if length $last;
                }
                &{$out}(to_bytes($drawn));
                ($last, $ends_nl) = ('text', $drawn =~ m/\n\z/ ? 1 : 0);
                return;
            }
            # the answer ends before thinking: the line that is open is drawn first
            if($last eq 'text' and length(my $rest = $md->flush)){
                &{$out}(to_bytes($rest));
                $ends_nl = $rest =~ m/\n\z/ ? 1 : 0;
            }
        }
        if($last ne $kind){
            # thinking and answer each start on a line of their own, without
            # the empty lines models put in between
            $text =~ s/\A\n+//;
            return unless length($text);
            &{$out}("\n") unless $ends_nl;
            &{$out}("\n") if length $last; # a blank line between thinking and answer
        }
        my $color = $kind eq 'think' ? $colors::think_color : $colors::green_color;
        &{$out}($color.to_bytes($text).$colors::reset_color);
        $last    = $kind;
        $ends_nl = $text =~ m/\n\z/ ? 1 : 0;
    };
    $p->{emit} = sub {
        my ($kind, $text) = @_;
        return unless length($text // '');
        return if $kind eq 'think' and !$show_thinking;
        $text = &{$visible}($text) if $o{hide_tools} and $kind eq 'text';
        return unless length($text);
        &{$show}($kind, $text);
    };
    $p->{finish} = sub {
        # a held back line that never became a tool call
        &{$show}('text', $hold) if length($hold) and !defined $in_tool;
        ($bol, $hold, $in_tool) = (1, '', undef);
        if($md and length(my $rest = $md->flush)){
            &{$out}(to_bytes($rest));
            $ends_nl = $rest =~ m/\n\z/ ? 1 : 0;
        }
        &{$out}("\n") unless $ends_nl;
        ($last, $ends_nl) = ('', 1);
    };
    return $p;
}

# A web page as text: no scripts and styles, links as [text](url), headings
# and list items marked, blocks on their own lines.
sub html_to_text {
    my ($html, $content_type) = @_;
    my ($charset) = ($content_type // '') =~ m/charset\s*=\s*["']?([\w.:-]+)/i;
    ($charset) = $html =~ m/<meta[^>]+charset\s*=\s*["']?([\w.:-]+)/i unless $charset;
    if($charset and $charset !~ m/^utf-?8$/i){
        $html = eval {Encode::decode($charset, $html)} // $html;
    } else {
        utf8::decode($html);
    }
    my ($title) = $html =~ m{<title\b[^>]*>(.*?)</title\s*>}is;
    $html =~ s/<!--.*?-->//gs;
    $html =~ s{<(script|style|noscript|svg|head|title|template|iframe)\b.*?</\1\s*>}{ }gis;
    $html =~ s{<a\b[^>]*?\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>(.*?)</a\s*>}{
        my ($href, $text) = ($1 // $2 // $3, $4);
        $text =~ s/<[^>]+>//g;
        $text =~ s/\s+/ /g;
        ($href =~ m/^(?:#|javascript:)/i or $text !~ m/\S/) ? $text : "[$text]($href)";
    }gise;
    $html =~ s{<h([1-6])\b[^>]*>}{"\n\n".('#' x $1).' '}gie;
    $html =~ s{<li\b[^>]*>}{\n- }gi;
    $html =~ s{<(?:br|hr)\b[^>]*>|</?(?:p|div|tr|table|ul|ol|pre|blockquote|section|article|header|footer|nav|form|h[1-6])\b[^>]*>}{\n}gi;
    $html =~ s{</t[dh]\s*>}{ | }gi;
    $html =~ s/<[^>]+>//g;
    my %ent = (amp => '&', lt => '<', gt => '>', quot => '"', apos => "'", nbsp => ' ',
        mdash => "\x{2014}", ndash => "\x{2013}", hellip => "\x{2026}", copy => "\x{a9}", laquo => "\x{ab}", raquo => "\x{bb}");
    my $entity = sub {
        my ($e) = @_;
        return chr(hex($1)) if $e =~ m/^#x([0-9a-f]+)$/i;
        return chr($1) if $e =~ m/^#(\d+)$/;
        return $ent{lc $e} // "&$e;";
    };
    foreach my $t ($html, $title){
        next unless defined $t;
        $t =~ s/&(#x[0-9a-f]+|#\d+|\w+);/$entity->($1)/gie;
        $t =~ s/\r//g;
        $t =~ s/[ \t\x{a0}]+/ /g;
        $t =~ s/ ?\n ?/\n/g;
        $t =~ s/\n{3,}/\n\n/g;
        $t =~ s/\A\s+//;
        $t =~ s/\s+\z//;
    }
    $title =~ s/\s+/ /g if defined $title;
    return to_bytes((length($title // '') ? "Title: $title\n\n" : "").$html."\n");
}

# how tool calls are shown: "brief" (one line per call, the first lines of the
# result, a diff for file changes) or "full" (the call as the model wrote it,
# the complete result)
sub tool_display {
    return lc($::ORIG_ENV{AI_TOOL_DISPLAY} // 'brief') eq 'full' ? 'full' : 'brief';
}

sub term_width {
    my $w = $::T ? eval {($::T->get_screen_size())[1]} : undef;
    return $w || $::ORIG_ENV{COLUMNS} || 100;
}

# a text for the terminal: at most $max lines, lines cut to the width
sub clip_lines {
    my ($text, $max, $prefix) = @_;
    $prefix //= '';
    my $width = term_width() - length($prefix) - 1;
    $width = 20 if $width < 20;
    my @lines = split m/\n/, $text // '';
    my $more = ($max and @lines > $max) ? @lines - $max : 0;
    splice(@lines, $max) if $more;
    my $r = join('', map {
        my $l = to_text($_) =~ s/\t/    /gr =~ s/[^\P{Cc}]//gr;
        $l = substr($l, 0, $width - 1)."\x{2026}" if length($l) > $width;
        $prefix.to_bytes($l)."\n";
    } @lines);
    $r .= $prefix."... +$more more line".($more == 1 ? "" : "s")."\n" if $more;
    return $r;
}

# one line that says what a tool call is about: its first argument
# what a sub-agent does, as it does it: one line above the status (AI_AGENT_VIEW=0 hides it)
sub agent_view {
    my ($who, $text) = @_;
    return unless $::ORIG_ENV{AI_AGENT_VIEW} // 1;
    $TUI->clear();
    $text =~ s/\s+/ /g;
    my $max = $TUI->width() - 2;
    $text = substr($text, 0, $max - 1).'...' if $max > 4 and length($text) > $max;
    print "${colors::blue_color3}\x{e2}\x{97}\x{8b} $who: $text${colors::reset_color}\n";
    return;
}

sub tool_summary {
    my ($c) = @_;
    my @lines = grep {m/\S/} split m/\n/, ($c->{args} // [])->[0] // '';
    return '' unless @lines;
    my $s = to_text($lines[0]) =~ s/^\s+//r =~ s/\s+/ /gr;
    my $max = term_width() - length($c->{k}) - 16;
    $max = 20 if $max < 20;
    $s = substr($s, 0, $max - 1)."\x{2026}" if length($s) > $max;
    $s .= " (+".(@lines - 1)." lines)" if @lines > 1;
    return to_bytes($s);
}

# Line diff of two texts: a list of [op, line] with op ' ', '-' or '+'.
# Common start and end are skipped first, the rest is a longest common
# subsequence (or, when that would get too big, everything out, everything in).
sub diff_lines {
    my ($old, $new) = @_;
    my @a = split m/\n/, $old // '', -1;
    my @b = split m/\n/, $new // '', -1;
    pop @a if @a and $a[-1] eq '';
    pop @b if @b and $b[-1] eq '';
    my ($s, $e) = (0, 0);
    $s++ while $s < @a and $s < @b and $a[$s] eq $b[$s];
    $e++ while $e < @a - $s and $e < @b - $s and $a[-1 - $e] eq $b[-1 - $e];
    my @ma = @a[$s .. $#a - $e];
    my @mb = @b[$s .. $#b - $e];
    my @mid;
    if(@ma * @mb > 4_000_000 or !@ma or !@mb){
        @mid = ((map {['-', $_]} @ma), (map {['+', $_]} @mb));
    } else {
        my @l = map {[(0) x (@mb + 1)]} 0 .. @ma;
        for(my $i = $#ma; $i >= 0; $i--){
            for(my $j = $#mb; $j >= 0; $j--){
                $l[$i][$j] = $ma[$i] eq $mb[$j] ? $l[$i + 1][$j + 1] + 1
                    : $l[$i + 1][$j] >= $l[$i][$j + 1] ? $l[$i + 1][$j] : $l[$i][$j + 1];
            }
        }
        my ($i, $j) = (0, 0);
        while($i < @ma and $j < @mb){
            if($ma[$i] eq $mb[$j]){
                push @mid, [' ', $ma[$i]]; $i++; $j++;
            } elsif($l[$i + 1][$j] >= $l[$i][$j + 1]){
                push @mid, ['-', $ma[$i++]];
            } else {
                push @mid, ['+', $mb[$j++]];
            }
        }
        push @mid, ['-', $ma[$i++]] while $i < @ma;
        push @mid, ['+', $mb[$j++]] while $j < @mb;
    }
    return ((map {[' ', $_]} @a[0 .. $s - 1]), @mid, (map {[' ', $_]} @a[@a - $e .. $#a]));
}

# A diff for the terminal: changed lines with $context lines around them,
# line numbers of the old file at each hunk, colors, at most $max lines.
# Returns ($text, $added, $removed).
sub format_diff {
    my ($old, $new, %o) = @_;
    my $context = $o{context} // 2;
    my @d = diff_lines($old, $new);
    my ($added, $removed) = (scalar(grep {$_->[0] eq '+'} @d), scalar(grep {$_->[0] eq '-'} @d));
    return ('', 0, 0) unless $added or $removed;
    # which lines to show
    my @keep = (0) x @d;
    foreach my $i (grep {$d[$_][0] ne ' '} 0 .. $#d){
        $keep[$_] = 1 for grep {$_ >= 0 and $_ <= $#d} $i - $context .. $i + $context;
    }
    my ($out, $ln, $shown, $gap) = ('', 1, 0, 1);
    my $max = $o{max} // 0;
    my $width = term_width() - 4;
    foreach my $i (0 .. $#d){
        my ($op, $line) = @{$d[$i]};
        if($keep[$i]){
            if($max and $shown >= $max){
                $out .= "  ${colors::cyan_color}... the diff goes on${colors::reset_color}\n";
                last;
            }
            $out .= "  ${colors::cyan_color}\@\@ line $ln \@\@${colors::reset_color}\n" if $gap;
            $gap = 0;
            my $l = to_text($line) =~ s/\t/    /gr =~ s/[^\P{Cc}]//gr;
            $l = substr($l, 0, $width - 1)."\x{2026}" if length($l) > $width;
            my $color = $op eq '+' ? $colors::green_color : $op eq '-' ? $colors::red_color : '';
            $out .= "  $color$op ".to_bytes($l).($color ? $colors::reset_color : '')."\n";
            $shown++;
        } else {
            $gap = 1;
        }
        $ln++ if $op ne '+';
    }
    return ($out, $added, $removed);
}

# show the file changes the tools just made (and forget them)
sub show_changes {
    my ($printer) = @_;
    my @changes = splice(@tools::CHANGES);
    return unless $printer and ($::ORIG_ENV{AI_SHOW_DIFF} // 1);
    foreach my $ch (@changes){
        my ($diff, $added, $removed) = format_diff($ch->{old}, $ch->{new}, max => $::ORIG_ENV{AI_DIFF_LINES} // 40);
        next unless length($diff);
        &{$printer}("  ${colors::cyan_color}$ch->{path}".(defined $ch->{old} ? "" : " (new)").": +$added -$removed${colors::reset_color}\n$diff");
    }
    return;
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
    my $printer = new_printer($o{quiet} ? sub {} : undef, hide_tools => (tool_display() eq 'brief' ? 1 : 0));
    # the status line tells that we wait, until there is something to show
    $TUI->set('model', $o{quiet} ? 'summarizing' : 'waiting for model');
    my $st;
    $st = new_stream(sub {
        my ($kind) = @_;
        $info->{t_first} //= Time::HiRes::time();
        if($o{quiet}){
            # nothing is shown of it
        } elsif($TUI->bar()){
            $TUI->set('model', $kind eq 'think' ? 'thinking' : 'answering');
        } else {
            $TUI->unset('model'); # one line: the text itself is in its place now
        }
        &{$printer->{emit}}(@_);
    });
    # how far the answer is, while it comes in
    my $cpt = load_usage()->{chars_per_token} || 3.5;
    $TUI->info(live => sub {
        return '' unless $info->{t_first};
        my $tokens = (length($st->{content}) + length($st->{reasoning})) / $cpt;
        my $took   = Time::HiRes::time() - $info->{t_first};
        return sprintf("%s~%s%s", tui::glyph(q(down)), fmt_k($tokens), $took > 0.5 ? sprintf(" %.0f/s", $tokens / $took) : "");
    }) if $TUI->bar();
    my $r = utils::http("post", $AI_URL, $req, $api_key, sub {
        my ($ch, $raw) = @_;
        $raw //= $ch; # WWW::Curl::Easy: <data>, <user_ref>, Net::Curl::Easy: <handle>, <data>
        log::info("GOT STREAM ".do {local $_ = $raw; chomp; chomp; $_});
        return 0 if utils::aborted(); # stops the transfer
        &{$st->{feed}}($raw);
        return length($raw);
    }, provider_headers($api_key));
    $TUI->info(live => undef);
    $TUI->unset('model');
    &{$st->{finish}}();
    &{$printer->{finish}}();
    $info->{t_end} = Time::HiRes::time();
    $info->{usage} = $st->{usage};
    $info->{timings} = $st->{timings};

    return ($st->{content}, "interrupted", $info) if utils::aborted();
    my ($err, $c) = completion_result($st, !defined $r, $utils::http_error, $utils::http_code, \%utils::http_headers);
    $info->{$_} = $c->{$_} for keys %$c;
    $info->{tool_calls} = stream_tool_calls($st);
    return ($st->{content}, $err, $info);
}

# headers of the API request for this provider, undef for the usual ones
sub provider_headers {
    my ($key) = @_;
    my $fn = "provider::$AI_PROVIDER"->can("headers") // provider->can("headers");
    return &{$fn}($key);
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
    $prompt .= prompt::coder::prompt(exclude => ['agent']) unless native_calls(); # the text syntax, see system_prompt()
    $prompt .= "\n\nYou are a sub-agent: another agent gave you the task below, the user is not here and you cannot ask questions. "
              ."Work on it with your tools. Your final answer, the one without a tool call, is all the other agent gets to see: "
              ."report what you found or did, complete but without the detours.\n";
    return $prompt.prompt_context();
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
    $n += length(to_bytes($_->{content} // '')) for @_;
    # the calls of the server are text too (name and JSON arguments)
    for my $call (map {@{$_->{tool_calls} // []}} @_){
        $n += length($call->{function}{name} // '') + length($call->{function}{arguments} // '');
    }
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
        my ($pp, $tg) = speeds($out, $info);
        $s .= sprintf(", pp %.1f tok/s", $pp) if defined $pp;
        $s .= sprintf(", %s%.1f tok/s", (defined $pp ? "tg " : ""), $tg) if defined $tg;
    }
    my $cached = cached_tokens($info);
    $s .= " | $cached cached" if $cached;
    return "[$s]";
}

# 1234 -> 1.2k
sub fmt_k {
    my ($n) = @_;
    $n //= 0;
    return sprintf("%.1fM", $n / 1e6) if $n >= 1e6;
    return sprintf("%dk", $n / 1000)  if $n >= 10_000;
    return sprintf("%.1fk", $n / 1000) if $n >= 1000;
    return int($n);
}

# Tokens per second of a request: (prompt processing, generation). From the
# timings a llama.cpp server reports; else the generation speed is measured
# here (from the first to the last piece of the answer) and the prompt speed
# is not known.
sub speeds {
    my ($out, $info) = @_;
    my $t = ref($info->{timings}) eq 'HASH' ? $info->{timings} : {};
    my ($pp, $tg) = @{$t}{qw(prompt_per_second predicted_per_second)};
    if(!defined $tg and $info->{t_end} and $info->{t_first}){
        my $gen = $info->{t_end} - $info->{t_first};
        $tg = $out / $gen if $out > 1 and $gen > 0.05;
    }
    return ($pp, $tg);
}

# how much of the prompt the server took from its cache, when it says so
sub cached_tokens {
    my ($info) = @_;
    my $u = ref($info->{usage}) eq 'HASH' ? $info->{usage} : {};
    my $d = ref($u->{prompt_tokens_details}) eq 'HASH' ? $u->{prompt_tokens_details} : {};
    my $t = ref($info->{timings}) eq 'HASH' ? $info->{timings} : {};
    return $d->{cached_tokens} // $u->{cached_tokens} // $t->{cache_n};
}

# The info line of the footer: session, model, context, tokens, and after a
# request how fast it was. Called whenever one of those may have changed.
sub status_info {
    my (%last) = @_; # out, info: the request that just ended
    return unless $TUI->enabled();
    my $u = load_usage();
    my ($in, $out) = ($u->{last_prompt_tokens} // 0, $u->{last_completion_tokens} // 0);
    my $limit = context_limit();
    my $est = $u->{estimated} ? '~' : '';
    $TUI->info(session => $AI_SESSION);
    $TUI->info(model   => length($SESSION_MODEL // '') ? $SESSION_MODEL : undef);
    $TUI->info(context => $limit ? sprintf("ctx %d%% of %s", 100 * ($in + $out) / $limit, fmt_k($limit))
                        : $in    ? "ctx $est".fmt_k($in + $out) : undef);
    $TUI->info(tokens  => $in ? sprintf("%s%s%s %s%s", tui::glyph(q(up)), $est, fmt_k($in), tui::glyph(q(down)), fmt_k($out)) : undef);
    $TUI->info(total   => $u->{total_tokens}
        ? tui::glyph(q(sum))." $est".fmt_k($u->{total_tokens}).($::ORIG_ENV{AI_TOKEN_BUDGET} ? " of ".fmt_k($::ORIG_ENV{AI_TOKEN_BUDGET}) : "")
        : undef);
    if($last{info}){
        my ($pp, $tg) = speeds($last{out} // 0, $last{info});
        $TUI->info(speed => (defined $pp or defined $tg)
            ? join(' ', (defined $pp ? sprintf("pp %.0f/s", $pp) : ()), (defined $tg ? sprintf("tg %.0f/s", $tg) : ()))
            : undef);
        my $cached = cached_tokens($last{info});
        $TUI->info(cache => $cached ? "cache ".fmt_k($cached) : undef);
    }
    return;
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
    return 1 if ($m->{role} // '') eq 'tool'; # a native result
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
# The reasoning of the model: 'on', 'off', a token budget (a number), or undef
# for what the server does. The session's choice (the file "thinking", set by
# /thinking) wins over AI_THINKING.
sub thinking_setting {
    my $v = defined $AI_SESSION_DIR ? slurp("$AI_SESSION_DIR/thinking") : undef;
    $v = undef if defined $v and $v !~ m/\S/;
    $v //= $::ORIG_ENV{AI_THINKING};
    return undef unless defined $v;
    $v =~ s/\s+//g;
    return undef unless length $v;
    return 'on'  if $v =~ m/^(?:on|yes|true|1)$/i;
    return 'off' if $v =~ m/^(?:off|no|false|0)$/i;
    return int($v) if $v =~ m/^\d+$/;
    return undef;
}

sub thinking_text {
    my $from = (defined $AI_SESSION_DIR and -f "$AI_SESSION_DIR/thinking") ? 'session'
        : defined $::ORIG_ENV{AI_THINKING} ? 'AI_THINKING' : 'default';
    return (thinking_setting() // 'server default')." ($from)";
}

# The first request of the conversation, kept in the session: a compaction
# takes it out of the chat, the summaries carry it on.
sub first_request {
    my (@msgs) = @_;
    my $kept = slurp("$AI_SESSION_DIR/first_request");
    if(!defined $kept){
        my ($first) = grep {is_user_input($_)} @msgs;
        return undef unless $first;
        $kept = to_bytes($first->{content} // '');
        eval {spew("$AI_SESSION_DIR/first_request", $kept); 1}
            or log::info("the first request is not kept: $@");
    }
    return to_text($kept);
}

# every compaction is written down: when, how, messages and tokens before/after
sub record_compaction {
    my (%e) = @_;
    $e{time} = time;
    open(my $fh, '>>', "$AI_SESSION_DIR/compactions") or return;
    print {$fh} $::JSON->encode(\%e)."\n";
    close($fh);
    return;
}

# The model's summary of some messages, written in pieces that fit a request:
# each piece updates the summary so far, so nothing in the middle is cut away
# the way one long request would cut it. The newest pieces count most: at most
# AI_SUMMARY_CHUNKS pieces (default 8) are summarized, the oldest are left out.
# Returns (summary, number of messages it covers); the summary is undef when
# not even the first piece could be done.
sub summarize_messages {
    my ($msgs, $limit) = @_;
    my $cpt  = load_usage()->{chars_per_token} || 3.5;
    my $room = int(($limit || 12_000) * 0.3 * $cpt); # characters per request, in the window
    $room = 4000 if $room < 4000;
    my @chunks = ([]);
    my $len = 0;
    for my $m (@$msgs){
        my $text = uc($m->{role} // 'user').":\n".($m->{content} // '');
        if(length($text) > $room / 2){
            # one huge message (a file, a long output): its start and its end
            $text = substr($text, 0, int($room / 2) - 100)."\n[...]\n".substr($text, -100);
        }
        if(@{$chunks[-1]} and $len + length($text) > $room){
            push @chunks, [];
            $len = 0;
        }
        push @{$chunks[-1]}, $text;
        $len += length($text);
    }
    my $max = $::ORIG_ENV{AI_SUMMARY_CHUNKS} // 8;
    splice(@chunks, 0, @chunks - $max) if $max and @chunks > $max;

    my ($summary, $covered) = (undef, 0);
    for my $i (0 .. $#chunks){
        my $so_far = defined $summary
            ? "The summary of the conversation so far:\n$summary\n\nThe next part of the conversation:\n\n"
            : "The conversation:\n\n";
        my @req = (
            {role => 'system', content => "You compact conversations between a user and a coding agent so that the work can continue with less context."},
            {role => 'user',   content => $so_far.join("\n\n", @{$chunks[$i]})."\n\n---\n"
                .(defined $summary ? "Update the summary above with the part before it: keep what still matters, add what changed. " : "Summarize the conversation above: ")
                ."the goals of the user, the decisions, what was done (files, commands and their relevant results), the current state and what is left to do. Be specific, keep file names, identifiers and error messages. Only the summary, no preamble, no tool calls."},
        );
        my ($resp, $err, $info) = request_completion(\@req, quiet => 1);
        return ($summary, $covered) if utils::aborted();
        record_usage(\@req, $resp, $info) unless defined $err and !length($resp);
        my $s = strip_thinking($resp) =~ s/\A\s+//r =~ s/\s+\z//r;
        if(defined $err or !length($s)){
            log::error("${colors::red_color}summary failed".(defined $err ? ": $err" : "")."${colors::reset_color}");
            last; # what there is so far stays
        }
        $summary = $s;
        $covered += scalar @{$chunks[$i]};
    }
    return ($summary, $covered);
}

sub compact_context {
    my (%o) = @_; # summarize => 1: always summarize, quiet => 1
    my @msgs   = load_messages();
    my $n_all  = scalar(@msgs);
    my $pin    = first_request(@msgs); # before anything is taken out
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
        my $after = estimate_tokens(@new);
        record_compaction(how => $how, messages => [$n_all, scalar(@new)], tokens => [$before, $after]);
        return if $o{quiet};
        print "${colors::cyan_color}[context: $how, ~$before -> ~$after tokens]${colors::reset_color}\n";
    };
    my $archive = \&archive_messages;

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

    # 2. a summary of the older part, written by the model, in pieces
    my ($summary, $covered) = (undef, 0);
    if(($::ORIG_ENV{AI_CONTEXT_SUMMARY} // 1) ne '0'){
        print "${colors::cyan_color}[context: summarizing ".scalar(@head)." older messages...]${colors::reset_color}\n"
            unless $o{quiet};
        ($summary, $covered) = summarize_messages(\@phead, $limit);
        return 0 if utils::aborted();
        if(!defined $summary){
            log::error("${colors::red_color}summary failed${colors::reset_color}");
        }
    }

    # 3. or without one
    my $pin_text = (defined $pin and length $pin)
        ? "\n\nThe first request of the user, word for word:\n".substr($pin, 0, 2000) : '';
    my $note = defined $summary
        ? "[Summary of the conversation so far, the older messages were removed to save context]\n$summary$pin_text"
        : "[The older messages of this conversation were removed to save context]$pin_text";
    my @new = (@sys, {role => 'user', content => $note}, @tail);
    &{$archive}(@head);
    write_messages(@new);
    &{$say}((defined $summary ? "summarized" : "dropped")." ".scalar(@head)." older messages", @new);
    return 1;
}

# messages that leave the conversation are kept in "chat.archive"
sub archive_messages {
    my (@gone) = @_;
    return unless @gone;
    open(my $fh, '>>', "$AI_SESSION_DIR/chat.archive")
        or die "Failed to write to $AI_SESSION_DIR/chat.archive: $!\n";
    print {$fh} $::JSON->encode($_)."\n" for @gone;
    close($fh);
    return;
}

# something the user said: not a tool result, not a note of the context management
sub is_user_input {
    my ($m) = @_;
    return 0 unless ($m->{role} // '') eq 'user' and !is_tool_result($m);
    return 0 if ($m->{content} // '') =~ m/\A\[(?:Summary of the conversation so far|The older messages of this conversation)/;
    return 1;
}

# Take the last $n exchanges out of the conversation: the last thing the user
# said and all that followed. Only the end changes, what a cache has of the
# start stays valid. Returns the removed messages, oldest first.
sub rewind_chat {
    my ($n) = @_;
    my @msgs = load_messages();
    my @gone;
    foreach (1 .. ($n || 1)){
        my ($i) = grep {is_user_input($msgs[$_])} reverse 0 .. $#msgs;
        last unless defined $i;
        unshift @gone, splice(@msgs, $i);
    }
    return unless @gone;
    archive_messages(@gone);
    write_messages(@msgs);
    return @gone;
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
# Returns true when the turn ended with an answer, false on an error.
sub chat_completion {
    my ($input) = @_;
    log::info("User input: $input");
    return 0 if over_budget();
    append_messages({role => 'user', content => to_text($input)});
    my $ok = 1; # false when the turn ended with an error

    my $max_turns = $::ORIG_ENV{AI_MAX_TURNS} // 50;
    my $retries   = $::ORIG_ENV{AI_RETRIES} // 4;
    my $max_wait  = $::ORIG_ENV{AI_RETRY_MAX_WAIT} // 120;
    my $turn = 0;
    my $compacted = 0; # after a "context too long" error, once per input
    while(1){
        last if utils::aborted();
        if($max_turns and ++$turn > $max_turns){
            log::error("${colors::red_color}stopped after $max_turns tool turns (AI_MAX_TURNS)${colors::reset_color}");
            $ok = 0;
            last;
        }
        if($turn > 1 and over_budget()){
            $ok = 0;
            last;
        }
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
        my $native = $info->{tool_calls} // []; # the calls the server made
        my %assistant = (role => 'assistant', content => $answer);
        $assistant{tool_calls} = [map {+{id => $_->{id}, type => 'function',
            function => {name => $_->{name}, arguments => $_->{arguments}}}} @$native]
            if @$native;
        append_messages(\%assistant)
            if length($answer) or @$native;
        if(!defined $err or length($resp)){
            my @u = record_usage(\@msgs, $resp, $info);
            status_info(out => $u[1], info => $info);
            # the footer has it all, the line is for when there is none
            print "${colors::cyan_color}".usage_line(@u, $info)."${colors::reset_color}\n"
                if ($::ORIG_ENV{AI_SHOW_USAGE} // ($TUI->bar() ? 0 : 1));
        }
        if(defined $err){
            $ok = 0;
            if(utils::aborted()){
                print "${colors::red_color}[interrupted]${colors::reset_color}\n";
            } else {
                log::error(${colors::red_color}.$err.${colors::reset_color});
            }
            last;
        }
        last unless length($answer) or @$native;

        # handle tools
        my ($newturns, undef, $r) = handle_llm_response(\$answer, undef, $native);
        append_messages(@{$r // []});
        last unless $newturns;
    }
    # between the turns: a conversation over the threshold is made smaller now,
    # not when the next message is sent (not for -p, which exits)
    manage_context() if $ok and !utils::aborted() and !$ONE_SHOT and ($::ORIG_ENV{AI_AUTO_COMPACT} // 1);
    return utils::aborted() ? 0 : $ok;
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
    # the tools section is the text syntax: with native calls the API has the tools
    if(!native_calls() and $template =~ m/^\w+$/ and UNIVERSAL::can("prompt::${template}", "prompt")){
        log::info("PROMPT check for 'prompt::${template}'");
        no strict "refs";
        $prompt .= &{"prompt::${template}::prompt"}() // "";
    }
    return $prompt.prompt_context();
}

# The date for the system prompt, as coarse as AI_PROMPT_DATE says: none,
# year, month (default), day, or a strftime format. A date that changes
# often would change the start of every request, and that is what an API
# caches on.
sub prompt_date {
    my $g = $::ORIG_ENV{AI_PROMPT_DATE} // 'month';
    return '' if $g =~ m/^(?:|none|off|no|0)$/i;
    my %fmt = (year => '%Y', month => '%B %Y', day => '%Y-%m-%d');
    return POSIX::strftime($fmt{lc $g} // $g, localtime());
}

# The instructions of the project in the working directory (AGENTS.md, or what
# AI_PROJECT_FILE names; empty for none).
sub project_instructions {
    my $files = $::ORIG_ENV{AI_PROJECT_FILE} // 'AGENTS.md';
    my $max   = $::ORIG_ENV{AI_PROJECT_FILE_MAX} // 32768;
    my $r = '';
    foreach my $file (grep {length} split m/[\s,:]+/, $files){
        next unless -f $file;
        my $data = slurp($file) // next;
        next unless $data =~ m/\S/;
        $data = substr($data, 0, $max)."\n[... $file is cut here, it is longer ...]\n"
            if $max and length($data) > $max;
        $data .= "\n" unless $data =~ m/\n\z/;
        $r .= "\n\n**PROJECT INSTRUCTIONS** (from $file in the working directory)\n\n$data";
    }
    return $r;
}

# What a system prompt ends with: the project instructions and the date. The
# most stable parts of the prompt come first, these last.
# The system prompt is made once, when a session starts (and on /clear and
# /prompt), and stored in the chat file. It is never changed behind the back
# of the model: the start of the conversation stays byte for byte the same,
# so the prefix cache of the API keeps working.
sub prompt_context {
    my $r = project_instructions();
    if(defined $WORKSPACE and $WORKSPACE ne '/'){
        $r .= "\n\nWorkspace: $WORKSPACE\nThe file tools only work inside this directory.\n";
        $r .= "bash, perl and grep can ".($::ORIG_ENV{AI_SANDBOX_READ} ? "only read the system and this directory" : "read everything")
             .", but only write in this directory and in ".tmpdir().".\n"
            if sandbox_state() eq 'on';
    }
    my $date = prompt_date();
    $r .= "\n\nCurrent date: $date\n" if length($date);
    return $r;
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
    unlink("$AI_SESSION_DIR/first_request"); # a new conversation has a new first request
    write_messages({role => 'system', content => to_text(system_prompt())});
    status_info();
    return;
}

sub get_sessions {
    my @sessions = glob("$SESSIONS_DIR/*");
    return  [sort map {$_ =~ s/.*\///; $_} grep {-d $_} @sessions];
}

sub list_sessions {
    foreach my $s (@{get_sessions()}) {
        my $i = session_info($s);
        my $line = sprintf("%s  %s", $s, format_age($i->{age}));
        $line .= "  ".to_bytes(clip_text($i->{first}, 50)) if length($i->{first});
        if ($s eq $AI_SESSION) {
            print "${colors::green_color}* $line${colors::reset_color}\n";
        } else {
            print "  $line\n";
        }
    }
}

sub format_age {
    my ($seconds) = @_;
    return sprintf("%dd", $seconds / 86400) if $seconds >= 86400;
    return sprintf("%dh", $seconds / 3600)  if $seconds >= 3600;
    return sprintf("%dm", $seconds / 60)    if $seconds >= 60;
    return "now";
}

# one line of a text, not longer than $max
sub clip_text {
    my ($text, $max) = @_;
    my $t = to_text($text // '') =~ s/\s+/ /gr =~ s/^ | $//gr;
    $t = substr($t, 0, $max - 1)."\x{2026}" if length($t) > $max;
    return $t;
}

# a session made up by this program, not named by the user
sub is_auto_name {
    my ($s) = @_;
    return $s =~ m/\Asession-[0-9A-Fa-f-]{16,}\z/ ? 1 : 0;
}

# What there is to know about a session without loading it: when it was last
# used (seconds ago), the first thing the user said, its size on disk, and
# whether there is anything in it worth keeping.
sub session_info {
    my ($s) = @_;
    my $dir = "$SESSIONS_DIR/$s";
    my $mtime = (stat("$dir/chat"))[9] // (stat($dir))[9] // time();
    my ($first, $messages, $said) = ('', 0, 0);
    if(open(my $fh, '<', "$dir/chat")){
        while(my $l = <$fh>){
            next unless $l =~ m/\S/;
            $messages++;
            my $m = eval {JSON::XS::decode_json($l)} // next;
            $said++ unless ($m->{role} // '') eq 'system' and $messages == 1;
            $first = $m->{content} if !length($first) and is_user_input($m);
            last if length($first) and $messages > 50;
        }
        close($fh);
    }
    my $size = 0;
    utils::load_cpan("File::Find");
    File::Find::find({no_chdir => 1, wanted => sub {$size += (lstat($_))[7] // 0 if -f $_ and !-l $_}}, $dir)
        if -d $dir;
    # nothing was said, set or done in it: only the system prompt is there
    my $empty = (!$said
        and !grep({-e "$dir/$_"} qw(model usage chat.archive agents))
        and !-s "$dir/undo/journal") ? 1 : 0;
    return {name => $s, mtime => $mtime, age => time() - $mtime, first => $first, size => $size, empty => $empty};
}

sub remove_session {
    my ($s) = @_;
    return unless valid_session_name($s) and -d "$SESSIONS_DIR/$s";
    utils::load_cpan("File::Path");
    File::Path::remove_tree("$SESSIONS_DIR/$s");
    delete $AUTO_SESSION{$s};
    return 1;
}

# At the end: a session this process made up a name for and in which nothing
# happened is not kept. (Sessions the user named stay, empty or not.)
sub drop_empty_sessions {
    return unless defined $SESSIONS_DIR;
    foreach my $s (keys %AUTO_SESSION){
        remove_session($s) if -d "$SESSIONS_DIR/$s" and session_info($s)->{empty};
    }
    return;
}

# At the start: what a crash left behind goes (empty sessions with a made-up
# name, older than a day), and with AI_SESSION_KEEP_DAYS every session that
# was not used for that many days, conversation or not. Never $keep, the
# session that is about to be used.
sub tidy_sessions {
    my ($keep) = @_;
    my $days = $::ORIG_ENV{AI_SESSION_KEEP_DAYS};
    $days = undef unless defined $days and $days =~ m/\A\d+(?:\.\d+)?\z/ and $days > 0;
    my $removed = 0;
    foreach my $s (@{get_sessions()}){
        next if $s eq ($keep // '');
        my $i = session_info($s);
        if(is_auto_name($s) and $i->{empty} and $i->{age} > 86400){
            remove_session($s);
        } elsif(defined $days and $i->{age} > $days * 86400){
            $removed += remove_session($s) ? 1 : 0;
        }
    }
    print STDERR "Removed $removed session".($removed == 1 ? "" : "s")." not used for $days days (AI_SESSION_KEEP_DAYS).\n"
        if $removed;
    return $removed;
}

# ask the user, true for a yes
sub confirm {
    my ($question) = @_;
    my $answer = $::T ? eval {$::T->readline("$question [y/N] ")} : do {
        print "$question [y/N] ";
        STDOUT->flush();
        scalar(<STDIN>);
    };
    return (($answer // '') =~ m/\A\s*y(?:es)?\s*\z/i) ? 1 : 0;
}

# /session prune [days] [yes]: remove the sessions that were not used for a
# while, after showing them and asking (not asked with "yes")
sub prune_sessions {
    my ($days, $yes) = @_;
    $days //= $::ORIG_ENV{AI_SESSION_KEEP_DAYS} || 30;
    my @old = sort {$b->{age} <=> $a->{age}} grep {$_->{name} ne $AI_SESSION and $_->{age} > $days * 86400}
        map {session_info($_)} @{get_sessions()};
    if(!@old){
        print "No sessions that were not used for $days days.\n";
        return 0;
    }
    my $size = 0;
    foreach my $i (@old){
        $size += $i->{size};
        printf "  %s  %s  %dk  %s\n", $i->{name}, format_age($i->{age}), ($i->{size} + 1023) / 1024,
            $i->{empty} ? "(empty)" : to_bytes(clip_text($i->{first}, 50));
    }
    my $what = scalar(@old)." session".(@old == 1 ? "" : "s")." not used for $days days, ".int(($size + 1023) / 1024)."k";
    if(!$yes and !confirm("Delete $what?")){
        print "Nothing deleted.\n";
        return 0;
    }
    remove_session($_->{name}) for @old;
    print "Deleted $what.\n";
    refresh_session_completions();
    return scalar(@old);
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
    utils::load_cpan("File::Path");
    File::Path::remove_tree("$SESSIONS_DIR/$name");
    print "Deleted session '$name'.\n";
    if ($name eq $AI_SESSION) {
        # there is always a session to chat in: a new, empty one
        my $new = "session-".new_session_id();
        $AUTO_SESSION{$new} = 1;
        init_session($new);
        use_session($new);
        print "Switched to session: $new\n";
    }
    refresh_session_completions();
}

# Start the current session over: the conversation, what was archived of it,
# the token counters, the undo journal and the transcripts of sub-agents are
# gone. Its name, system prompt, model and input history stay.
sub reset_session {
    utils::load_cpan("File::Path");
    File::Path::remove_tree("$AI_SESSION_DIR/$_") for qw(undo agents);
    unlink(map {"$AI_SESSION_DIR/$_"} qw(chat.archive usage chat.tmp usage.tmp compactions));
    reset_chat();
    print "Session '$AI_SESSION' reset.\n";
    return;
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
    status_info();
    print "Switched model to '$new_model'.\n";
}

# the model list of the API, undef when it can't be fetched
sub fetch_models {
    my $response = eval {utils::http("get", "$AI_ENDPOINT_URL/v1/models", undef, $api_key, undef, provider_headers($api_key))};
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

# The undo journal of the session: every file change of the tools, newest last
sub undo_journal {
    my $data = slurp("$AI_SESSION_DIR/undo/journal") // '';
    return grep {ref($_) eq 'HASH'} map {eval {JSON::XS::decode_json($_)}} grep {m/\S/} split m/\n/, $data;
}

sub undo_describe {
    my ($e) = @_;
    my $what = $e->{op} eq 'move' ? "$e->{path} -> $e->{to}" : $e->{path};
    return "$e->{tool} $what".($e->{op} eq 'write' && !$e->{existed} ? " (new file)" : "");
}

# Take back the last file change a tool made. Returns what was undone, dies
# when that is not possible.
sub undo_last {
    my @j = undo_journal();
    my $e = pop @j
        or die "nothing to undo\n";
    my $dir = "$AI_SESSION_DIR/undo";
    my $restore = sub {
        die "no copy of the old content was kept\n" unless defined $e->{backup};
        my $old = slurp("$dir/$e->{backup}") // die "the copy of the old content is gone\n";
        open(my $fh, '>', $e->{path}) or die "cannot write $e->{path}: $!\n";
        print {$fh} $old;
        close($fh) or die "cannot write $e->{path}: $!\n";
        chmod($e->{mode} & 07777, $e->{path}) if defined $e->{mode};
    };
    if($e->{op} eq 'write' and $e->{existed}){
        &{$restore}();
    } elsif($e->{op} eq 'write'){
        unlink($e->{path}) or die "cannot delete $e->{path}: $!\n" if -e $e->{path};
    } elsif($e->{op} eq 'delete'){
        die "$e->{path} exists again\n" if -e $e->{path};
        &{$restore}();
    } elsif($e->{op} eq 'rmdir'){
        mkdir($e->{path}) or die "cannot create $e->{path}: $!\n";
    } elsif($e->{op} eq 'move'){
        die "$e->{path} exists again\n" if -e $e->{path};
        rename($e->{to}, $e->{path}) or die "cannot move $e->{to} back: $!\n";
    } elsif($e->{op} eq 'mkdir'){
        rmdir($_) for reverse @{$e->{created} // []};
    }
    unlink("$dir/$e->{backup}") if defined $e->{backup};
    spew("$dir/journal", join('', map {JSON::XS->new->utf8->canonical->encode($_)."\n"} @j));
    return $e;
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
            foreach my $name (grep {tools::available($_)} sort keys %$tools::TOOLS) {
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
    '/workspace' => {
        usage => '/workspace [dir|none]',
        help  => 'show or set the directory the file tools are confined to',
        run   => sub {
            my ($args) = @_;
            if(length($args)){
                eval {set_workspace($args); 1}
                    or print "Cannot set the workspace: $@";
            }
            print "Workspace: ".($WORKSPACE // 'none, the file tools can go anywhere')."\n";
            print "Also allowed: @WORKSPACE_ALLOW\n" if @WORKSPACE_ALLOW;
            my $state = sandbox_state();
            my %p = sandbox_policy();
            print "Sandbox for bash, perl, grep: "
                .($state eq 'on' ? "landlock (kernel ABI ".sandbox::abi().")\n"
                    ."  write: ".join(' ', grep {-e $_} @{$p{write}})."\n"
                    ."  read:  ".($p{read} ? join(' ', grep {-e $_} @{$p{read}})." + the above" : "everything")."\n"
                : $state eq 'unavailable' ? "not available, this kernel has no landlock\n"
                : "off\n");
            return 0;
        },
    },
    '/pwd' => {
        help => 'print the working directory',
        run  => sub {print Cwd::cwd()."\n"; 0},
    },
    '/session' => {
        usage => '/session [list|create|delete|rename|switch|reset|prune] [name]',
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
            } elsif ($sub eq 'prune' and $rest =~ m/\A(?:(\d+(?:\.\d+)?)\s*)?(yes|-y)?\z/) {
                prune_sessions($1, $2);
            } elsif ($sub eq 'prune') {
                print "Usage: /session prune [days] [yes]\n";
            } elsif ($sub eq 'reset' and $rest eq '') {
                reset_session();
            } elsif ($sub eq 'rename' and $rest =~ m/^(\S+)$/) {
                rename_session($AI_SESSION, $1); # one name: the current session
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
                'reset'  => sub {0},
                'prune'  => sub {0},
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
                status_info();
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
    '/retry' => {
        help => 'ask the last request again: its answer and tool runs are dropped',
        run  => sub {
            my @gone = rewind_chat(1);
            if(!@gone){
                print "Nothing to retry.\n";
                return 0;
            }
            local $BUSY = 1;
            $::ABORT = 0;
            chat_completion(to_bytes($gone[0]{content}));
            $::ABORT = 0;
            return 0;
        },
    },
    '/rewind' => {
        usage => '/rewind [n]',
        help  => 'take the last exchange (or n) out of the conversation',
        run   => sub {
            my ($args) = @_;
            if(length($args) and $args !~ m/^[1-9]\d*$/){
                print "Usage: /rewind [n]\n";
                return 0;
            }
            my @gone = rewind_chat($args || 1);
            if(!@gone){
                print "Nothing to rewind.\n";
                return 0;
            }
            my @inputs = grep {is_user_input($_)} @gone;
            print "Removed ".scalar(@inputs)." exchange".(@inputs == 1 ? "" : "s")." (".scalar(@gone)." messages), back to before:\n";
            print to_bytes(clip_lines($inputs[0]{content}, 2, "  "));
            return 0;
        },
    },
    '/context' => {
        usage => '/context [summary]',
        help  => 'how full the context is and its compactions; "summary" shows the last summary',
        run   => sub {
            my ($args) = @_;
            my @msgs = load_messages();
            if(($args // '') eq 'summary'){
                my ($note) = grep {($_->{content} // '') =~ m/\A\[Summary of the conversation so far/} reverse @msgs;
                print $note ? "$note->{content}\n" : "No summary yet.\n";
                return 0;
            }
            my $tok   = estimate_tokens(@msgs);
            my $limit = context_limit();
            printf "messages:    %d\n", scalar(@msgs);
            printf "tokens:      ~%d%s\n", $tok, $limit ? sprintf(" of %d (%d%%)", $limit, 100 * $tok / $limit) : " (window unknown)";
            my $archive = slurp("$AI_SESSION_DIR/chat.archive") // '';
            printf "archived:    %d messages\n", scalar(() = $archive =~ m/\n/g);
            my @c = grep {ref($_) eq 'HASH'} map {eval {$::JSON->decode($_)}} grep {m/\S/} split /\n/, slurp("$AI_SESSION_DIR/compactions") // '';
            printf "compactions: %d\n", scalar(@c);
            if(@c){
                my $l = $c[-1];
                printf "last:        %s, %s -> %s messages, ~%s -> ~%s tokens (%s)\n", scalar(localtime($l->{time})),
                    $l->{messages}[0], $l->{messages}[1], $l->{tokens}[0], $l->{tokens}[1], $l->{how};
            }
            print "thinking:    ".thinking_text()."\n";
            return 0;
        },
    },
    '/thinking' => {
        usage => '/thinking [on|off|<tokens>|default]',
        help  => 'the reasoning of the model in this session: on, off, a token budget, or the default',
        run   => sub {
            my ($args) = @_;
            $args = lc(utils::trim($args // ''));
            if(length $args){
                if($args eq 'default'){
                    unlink("$AI_SESSION_DIR/thinking");
                } elsif($args =~ m/^(?:on|off|\d+)$/){
                    if(!eval {spew("$AI_SESSION_DIR/thinking", $args); 1}){
                        print "Failed to set thinking: $@";
                        return 0;
                    }
                } else {
                    print "Usage: /thinking on|off|<tokens>|default\n";
                    return 0;
                }
            }
            print "thinking: ".thinking_text()."\n";
            return 0;
        },
        complete => sub {return +{map {($_ => sub {0})} qw(on off default)}},
    },
    '/voice' => {
        usage => '/voice [seconds]',
        help  => 'talk: Enter starts, then Enter or a pause sends the words, Esc cancels (or a number of seconds)',
        run   => sub {
            my ($args) = @_;
            # a number: that long; nothing, at a terminal: push to talk; else the default length
            my $secs = ($args // '') =~ m/^\s*(\d+(?:\.\d+)?)\s*$/ ? $1
                : ($args // '') =~ m/\S/ ? ($::ORIG_ENV{AI_VOICE_SECONDS} // 5)
                : (-t STDIN) ? undef
                : ($::ORIG_ENV{AI_VOICE_SECONDS} // 5);
            my $text = do {local $BUSY = 1; voice_once($secs)};
            if(!defined $text){
                print "Nothing heard.\n" unless utils::aborted() or $ai::VOICE_CANCELLED;
                $::ABORT = 0;
                return 0;
            }
            print "${colors::blue_color3}heard:${colors::reset_color} ".to_text($text)."\n";
            chat_completion(to_text($text));
            $::ABORT = 0;
            return 0;
        },
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
    '/undo' => {
        usage => '/undo [list]',
        help  => 'take back the last file change of a tool, "list" shows them',
        run   => sub {
            my ($args) = @_;
            if($args eq 'list'){
                my @j = undo_journal();
                print "Nothing to undo.\n" unless @j;
                my $n = @j;
                print sprintf("%3d  ", $n--).undo_describe($_)."\n" for reverse @j;
                return 0;
            }
            my $e = eval {undo_last()};
            if(!$e){
                print "Cannot undo: $@";
                return 0;
            }
            print "Undone: ".undo_describe($e)."\n";
            return 0;
        },
        complete => sub {return +{list => sub {0}}},
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
        $TUI->resize(); # the footer moves to the new bottom
        fit_readline();
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
    # with the footer on, it shows the session and the model: the prompt is short
    my $prompt_term1  = ($TUI and $TUI->bar())
        ? ($::ORIG_ENV{AI_PS1}
        //   $colors::reset_color.$colors::blue_color3.tui::glyph(q(arrow)).' '.$colors::reset_color)
        : ($::ORIG_ENV{AI_PS1}
        //   $colors::reset_color
            .$colors::blue_color3
            .tui::glyph(q(open)).'$AI_SESSION'.($SESSION_MODEL?'\[$SESSION_MODEL\]':'').tui::glyph(q(close)).' '.tui::glyph(q(arrow)).' '
            .$colors::reset_color);
    my $prompt_term2  =
            $::ORIG_ENV{AI_PS2}
        //   $colors::reset_color
            .$colors::blue_color3
            .tui::glyph(q(bar)).' '
            .$colors::reset_color;
    my $ps1 = eval 'return "'.$prompt_term1.'"' || tui::glyph(q(arrow)).' ';
    my $ps2 = eval 'return "'.$prompt_term2.'"' || tui::glyph(q(bar)).' ';
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

# the status line, animated by the event loop
sub start_status_line {
    my (%o) = @_;
    $TUI = tui->new($o{bar} ? () : (mode => 'line'));
    # the footer: the lines above it are what readline has to work with
    fit_readline() if $o{bar} and $TUI->open();
    status_info();
    $TUI->clear();
    $log::before_print = sub {$TUI->clear()};
    $loop::on_tick = sub {$TUI->tick()};
    $loop::on_idle = sub {$TUI->clear()};
    return;
}

# One request and done (ai.pl -p): returns the exit code, 0 when the model
# answered, 1 on an error, 130 when interrupted.
# Speech: the microphone is recorded by a recorder (AI_RECORDER, pw-record by
# default) started as a child, the recording goes to the speech recognizer
# (AI_ASR_URL, an OpenAI compatible /v1/audio/transcriptions, e.g. FastFlowLM on
# the NPU), and the text is the next request.

# the path of a program: as it is when it has a slash, else searched in PATH
sub find_program {
    my ($name) = @_;
    return $name if $name =~ m{/} and -x $name;
    for my $dir (split /:/, $::ORIG_ENV{PATH} // '/usr/local/bin:/usr/bin:/bin') {
        return "$dir/$name" if length($dir) and -x "$dir/$name";
    }
    return;
}

# start the recorder on $file: a child in the event loop. Returns the job, or
# undef when there is no recorder. The recorder finishes the file on SIGINT.
# a WAV file of 16-bit mono PCM at 16 kHz, the format of the recorder
sub wav_of_pcm {
    my ($pcm) = @_;
    return 'RIFF'.pack('V', 36 + length $pcm).'WAVE'.'fmt '.pack('V', 16)
        .pack('vvVVvv', 1, 1, 16000, 32000, 2, 16).'data'.pack('V', length $pcm).$pcm;
}

# the loudest sample of 16-bit PCM bytes, 0 to 32767
sub pcm_peak {
    my ($pcm) = @_;
    my $peak = 0;
    foreach my $sample (unpack('s<*', substr($pcm, 0, length($pcm) - length($pcm) % 2))){
        my $abs = abs($sample);
        $peak = $abs if $abs > $peak;
    }
    return $peak;
}

# the level of a recording while it is made: the loudest sample of the last
# quarter second, from 0 (silence, -60 dB and below) to 1 (full scale)
sub voice_level {
    my ($file) = @_;
    open(my $fh, '<:raw', $file) or return 0;
    my $size = -s $fh // 0;
    seek($fh, $size > 8000 ? $size - 8000 : 0, 0);
    my $got = read($fh, my $buf, 8000) // 0;
    close($fh);
    my $peak = pcm_peak(substr($buf, 0, $got));
    return 0 unless $peak;
    my $level = (20 * log($peak / 32768) / log(10) + 60) / 60;
    return $level < 0 ? 0 : $level > 1 ? 1 : $level;
}

# the last levels of the recording in progress, for the footer
our @VOICE_LEVELS;

# the footer item of a recording: the record glyph and eight level cells
sub voice_meter {
    my $bars = tui::glyph('levels');
    my @cells = map {$bars->[int($_ * (@$bars - 1) + 0.5)]} @VOICE_LEVELS;
    unshift @cells, ($bars->[0]) x (8 - @cells);
    return tui::glyph('rec').' '.join('', @cells);
}

# samples the level of the file, every 0.15 s, until the flag is cleared
sub voice_meter_start {
    my ($file, $alive) = @_;
    my $pause = $::ORIG_ENV{AI_VOICE_PAUSE} // 1.2;
    my ($spoke, $quiet_since) = (0, undef);
    my $sample;
    $sample = sub {
        if(!$$alive){
            undef $sample; # the closure refers to itself
            return;
        }
        my $level = voice_level($file);
        push @VOICE_LEVELS, $level;
        shift @VOICE_LEVELS while @VOICE_LEVELS > 8;
        my $now = Time::HiRes::time();
        if($level >= 0.17){ # speech: about -50 dB and louder
            $spoke = 1;
            $quiet_since = undef;
        } elsif($spoke){
            $quiet_since //= $now;
            if($now - $quiet_since >= $pause and $ai::VOICE_END){
                $spoke = 0;
                $ai::VOICE_END->();
            }
        }
        loop::timer(0.15, $sample);
    };
    $sample->();
    return;
}

# the preview of the recording in progress: the words that are final (two
# passes agree on them) and the provisional ones of the last pass
our @HEARD_COMMITTED;
our @HEARD_PROVISIONAL;

sub voice_heard {
    my $t = join(' ', grep {length} @HEARD_COMMITTED, @HEARD_PROVISIONAL);
    $t =~ s/\s+/ /g;
    $t =~ s/\A //;
    $t =~ s/ \z//;
    return tui::glyph('ellipsis') unless length $t;
    # the newest words: what is left of the footer line after the meter
    my $max = ($TUI->width() // 80) - 30;
    $max = 20 if $max < 20;
    return length($t) > $max ? tui::glyph('ellipsis').substr($t, -$max) : $t;
}

sub heard_norm {
    my ($t) = @_;
    $t = lc($t // '');
    $t =~ s/[^\w]+//g;
    return $t;
}

# LocalAgreement over the segments of two passes on the same audio: the
# segments both passes give the same way are final. The last segment never is
# (it is cut off where the audio ends). Without agreement, a buffer of more
# than 25 seconds is committed up to its last segment. Returns how many
# segments are final, and the seconds of audio they cover.
sub heard_agree {
    my ($segs, $prev, $seconds) = @_;
    my $n = @$segs;
    my $c = 0;
    while($c < $n - 1 and $c < @$prev and heard_norm($segs->[$c]{text}) eq heard_norm($prev->[$c]{text})){
        $c++;
    }
    $c = $n - 1 if $c == 0 and $n > 1 and $seconds > 25;
    return ($c, $c ? ($segs->[$c - 1]{end} // 0) : 0);
}

# where the data of a WAV file starts; undef while its header is not there
sub wav_data_start {
    my ($file) = @_;
    open(my $fh, '<:raw', $file) or return;
    my $n = read($fh, my $head, 256) // 0;
    close($fh);
    my $at = index(substr($head, 0, $n), 'data');
    return ($at < 0 or $at + 8 > $n) ? undef : $at + 8;
}

# the audio buffer to the recognizer as verbose JSON; $done gets the segments
# [{text, end}] (end in seconds from the start of the audio), or undef when it
# failed
sub voice_preview_send {
    my ($pcm, $done) = @_;
    my $boundary = 'aicli'.int(rand(1e9)).'x'.int(rand(1e9));
    my $body = multipart_body($boundary, asr_parts(), ['response_format', 'verbose_json'], ['file', wav_of_pcm($pcm), 'voice.wav', 'audio/wav']);
    loop::http(
        method  => 'post',
        url     => $::ORIG_ENV{AI_ASR_URL},
        data    => $body,
        timeout => 60,
        headers => ["Content-Type: multipart/form-data; boundary=$boundary", "Accept: application/json", "User-Agent: AI Chat/0.1"],
        on_done => sub {
            my ($r) = @_;
            my $d = eval {$::JSON->decode($r->{body} // '')};
            my $segs;
            if(ref($d) eq 'HASH'){
                if(ref($d->{segments}) eq 'ARRAY'){
                    $segs = [map {+{text => $_->{text} // '', end => $_->{end} // 0}} grep {ref($_) eq 'HASH'} @{$d->{segments}}];
                } elsif(defined $d->{text}){
                    $segs = [{text => $d->{text}, end => length($pcm) / 32000}];
                }
            }
            $done->($segs);
        },
    );
    return;
}

# every three seconds of new audio, the whole audio since the last final words
# goes to the recognizer while the recording is made: one request at a time,
# and audio without sound is not sent
sub voice_preview_start {
    my ($file, $alive) = @_;
    my $rate = 32000; # bytes per second: 16 kHz, 16 bit, mono
    my ($at, $sent_to, $busy, $prev) = (undef, 0, 0, []);
    my $tick;
    $tick = sub {
        if(!$$alive){
            undef $tick; # the closure refers to itself
            return;
        }
        if(!$busy){
            $at //= wav_data_start($file);
            my $size = -s $file // 0;
            if(defined $at){
                $size -= ($size - $at) % 2; # whole samples
                if($size - $sent_to >= 3 * $rate and open(my $fh, '<:raw', $file)){
                    seek($fh, $at, 0);
                    my $n = read($fh, my $pcm, $size - $at) // 0;
                    close($fh);
                    $sent_to = $at + $n;
                    if(pcm_peak($pcm) >= 100){ # about -50 dB: speech this quiet still counts
                        $busy = 1;
                        my $seconds = $n / $rate;
                        log::info("voice preview: pass of $seconds s");
                        voice_preview_send($pcm, sub {
                            my ($segs) = @_;
                            $busy = 0;
                            log::info("voice preview: ".(defined $segs ? scalar(@$segs)." segments" : "no answer"));
                            return unless $segs;
                            my ($c, $trim) = heard_agree($segs, $prev, $seconds);
                            if($c){
                                push @HEARD_COMMITTED, map {$_->{text}} @$segs[0 .. $c - 1];
                                $at += int($trim * $rate / 2) * 2;
                                $prev = [map {+{text => $_->{text}, end => $_->{end} - $trim}} @$segs[$c .. $#$segs]];
                            } else {
                                $prev = $segs;
                            }
                            @HEARD_PROVISIONAL = map {$_->{text}} @$prev;
                        });
                    } elsif($sent_to - $at > 25 * $rate){
                        # silence for long: the buffer starts after it
                        $at = $sent_to;
                        $prev = [];
                        @HEARD_PROVISIONAL = ();
                    }
                }
            }
        }
        loop::timer(0.25, $tick);
    };
    loop::timer(0.25, $tick);
    return;
}

sub voice_start {
    my ($file) = @_;
    my $rec = $::ORIG_ENV{AI_RECORDER} // 'pw-record';
    my $bin = find_program($rec)
        or do { log::error("no recorder: $rec is not installed (AI_RECORDER)"); return };
    unlink $file;
    my $alive = 1;
    my $preview = length($::ORIG_ENV{AI_ASR_URL} // '') ? 1 : 0;
    @HEARD_COMMITTED = ();
    @HEARD_PROVISIONAL = ();
    my $job = loop::spawn(sub {
        exec {$bin} ($rec, '--rate', '16000', '--channels', '1', '--format', 's16', $file)
            or die "cannot run $bin: $!\n";
    }, on_done => sub {
        my ($out) = @_;
        $alive = 0;
        $TUI->unset('recording');
        $TUI->unset('heard') if $preview;
        # no file: say why, in the recorder's own words (not for a ctrl-C)
        if(!-s $file and !utils::aborted()){
            my $said = to_text($out // '') =~ s/\s+/ /gr =~ s/^ | $//gr;
            log::error("the recorder $rec wrote no recording".(length($said) ? ": $said" : ""));
        }
        $ai::VOICE_DONE->() if $ai::VOICE_DONE;
    });
    $job->{started} = Time::HiRes::time();
    @VOICE_LEVELS = ();
    $TUI->set('recording', \&voice_meter);
    voice_meter_start($file, \$alive);
    if($preview){
        $TUI->set('heard', \&voice_heard);
        voice_preview_start($file, \$alive);
    }
    return $job;
}

# the recorder gets SIGINT, and is killed when it does not finish after a while
sub voice_stop {
    my ($job) = @_;
    return unless $job and $loop::child{$job->{pid}};
    # a recorder that is only starting does not know SIGINT yet: give it a moment
    my $wait = ($job->{started} // 0) + 0.5 - Time::HiRes::time();
    if($wait > 0){
        loop::timer($wait, sub {voice_stop($job)});
        return;
    }
    kill('INT', -$job->{pid}, $job->{pid});
    loop::timer(3, sub {kill('KILL', -$job->{pid}, $job->{pid}) if $loop::child{$job->{pid}}});
    return;
}

# record $seconds of audio into $file. Returns true when the recording is there.
sub voice_record {
    my ($file, $seconds) = @_;
    my $done = 0;
    local $ai::VOICE_DONE = sub {$done = 1};
    my $job = voice_start($file) or return 0;
    loop::timer($seconds, sub {voice_stop($job) unless $done});
    loop::run(sub {$done or utils::aborted()});
    voice_stop($job) if utils::aborted() and !$done;
    return 0 if utils::aborted();
    return -s $file ? 1 : 0;
}

# push to talk: Enter starts the recording, Enter again stops it. Without a
# terminal (a pipe), or with a number of seconds, it is a timed recording.
# AI_VOICE_MAX seconds at most (60 by default).
sub voice_ptt {
    my ($file) = @_;
    my $max = $::ORIG_ENV{AI_VOICE_MAX} // 60;
    print "${colors::cyan_color}[press Enter to start talking; then Enter sends now, a pause sends it, Esc cancels, ctrl-C ends]${colors::reset_color}\n";
    my ($job, $done, $stage, $cancelled) = (undef, 0, 0, 0); # stage: 0 waiting for the start, 1 recording, 2 over
    my $stop = sub {
        return if $stage == 2;
        $stage = 2;
        loop::unwatch(\*STDIN);
        voice_stop($job) if $job;
    };
    # Esc: the sentence is dropped, nothing is sent
    my $cancel = sub {
        return if $cancelled or $stage == 2;
        $cancelled = 1;
        if($stage == 1){
            $stop->(); # the recorder ends, then $done
        } else {
            $stage = 2;
            loop::unwatch(\*STDIN);
            $done = 1;
        }
    };
    local $ai::VOICE_DONE = sub {$done = 1};
    # a pause after the speech (voice_meter_start) sends it
    local $ai::VOICE_END = sub {$stop->() if $stage == 1};
    loop::watch(\*STDIN, sub {
        my $buf;
        my $n = sysread(STDIN, $buf, 4096);
        if(!$n){ # the input ended: what is recorded is the request, else nothing
            $stage == 1 ? $stop->() : $cancel->();
            return;
        }
        (my $keys = $buf) =~ s/\e\[[0-9;?]*[ -\/]*[@-~]//g; # arrow keys and the like
        for my $key (split //, $keys){
            if($key eq "\n" or $key eq "\r"){
                if($stage == 0){
                    $job = voice_start($file) or do { $stage = 2; loop::unwatch(\*STDIN); $done = 1; return };
                    $stage = 1;
                    print "${colors::cyan_color}[recording: Enter sends now, Esc cancels]${colors::reset_color}\n";
                    loop::timer($max, sub {$stop->() unless $done});
                } elsif($stage == 1){
                    $stop->();
                    return;
                } else {
                    return;
                }
            } elsif($key eq "\e"){
                $cancel->();
                return;
            }
        }
    });
    loop::run(sub {$done or utils::aborted()});
    loop::unwatch(\*STDIN);
    $stop->() unless $stage == 2;
    voice_stop($job) if utils::aborted() and $job and !$done;
    return 0 if utils::aborted();
    return 'cancel' if $cancelled;
    return -s $file ? 1 : 0;
}

# a multipart/form-data body; each part is [name, value, filename, content type]
sub multipart_body {
    my ($boundary, @parts) = @_;
    my $body = '';
    for my $p (@parts){
        my ($name, $value, $filename, $type) = @$p;
        $body .= "--$boundary\r\n";
        $body .= qq{Content-Disposition: form-data; name="$name"} . (defined $filename ? qq{; filename="$filename"} : '') . "\r\n";
        $body .= "Content-Type: $type\r\n" if $type;
        $body .= "\r\n$value\r\n";
    }
    return $body."--$boundary--\r\n";
}

# the fields every recognizer request has: the model, and AI_ASR_PROMPT (words
# the recognizer should spell as given, e.g. "Code me, Perl") when it is set
sub asr_parts {
    my @parts = (['model', $::ORIG_ENV{AI_ASR_MODEL} // 'whisper-large-v3-turbo']);
    push @parts, ['prompt', $::ORIG_ENV{AI_ASR_PROMPT}] if length($::ORIG_ENV{AI_ASR_PROMPT} // '');
    return @parts;
}

# the text of a recording, from the speech recognizer; undef when it failed
sub transcribe {
    my ($file) = @_;
    my $url = $::ORIG_ENV{AI_ASR_URL}
        or do { log::error("no speech recognizer set: AI_ASR_URL (e.g. http://localhost:52625/v1/audio/transcriptions)"); return };
    open(my $fh, '<:raw', $file) or do { log::error("cannot read $file: $!"); return };
    my $wav = do { local $/; <$fh> };
    close($fh);
    my $boundary = 'aicli'.int(rand(1e9)).'x'.int(rand(1e9));
    my $body = multipart_body($boundary, asr_parts(), ['response_format', 'json'], ['file', $wav, 'voice.wav', 'audio/wav']);
    my $resp = '';
    utils::http('post', $url, $body, undef, sub {
        my ($ch, $raw) = @_;
        $raw //= $ch;
        $resp .= $raw;
        return length($raw);
    }, [
        "Content-Type: multipart/form-data; boundary=$boundary",
        "Accept: application/json",
        "User-Agent: AI Chat/0.1",
    ]);
    if(utils::aborted()){
        return;
    }
    my $d = eval {$::JSON->decode($resp)};
    if(ref($d) ne 'HASH' or !defined $d->{text}){
        log::error("${colors::red_color}no text from the speech recognizer: ".($resp =~ s/\s+/ /gr).$colors::reset_color);
        return;
    }
    my $text = $d->{text} =~ s/\A\s+|\s+\z//gr;
    return $text;
}

# one utterance: record, transcribe. Returns the text, undef when there is none
# true when a recording has no sound in it: the recognizer makes up a word
# for silence ("you"), so it is not sent. The loudest sample of the 16-bit PCM
# data must reach at least 100 (about -50 dBFS). A file that is not a WAV
# with data counts as sound.
sub voice_quiet {
    my ($file) = @_;
    my $d = slurp($file) // return 0;
    my $at = index($d, 'data');
    return 0 if $at < 0 or length($d) < $at + 8;
    my $pcm = substr($d, $at + 8, unpack('V', substr($d, $at + 4, 4)));
    my $peak = 0;
    for my $sample (unpack('s<*', substr($pcm, 0, length($pcm) - length($pcm) % 2))){
        my $abs = abs($sample);
        $peak = $abs if $abs > $peak;
    }
    return $peak < 100; # about -50 dB
}

# where a recording goes: a directory of this user in the temp dir. The
# recorder is confined by the sandbox to the workspace and the temp dir, the
# session directory is neither. Made 0700; undef (with the reason) when it
# cannot be used.
sub voice_dir {
    my $dir = tmpdir()."/aicli-$<";
    if(!-d $dir){
        mkdir($dir, 0700) or do {
            log::error("cannot make $dir for the recording: $!");
            return;
        };
    }
    my @st = stat($dir);
    if(!@st or $st[4] != $< or ($st[2] & 077)){
        log::error("$dir is not private to this user (owner or mode): not used for the recording");
        return;
    }
    return $dir;
}

our $VOICE_CANCELLED; # set when the last sentence was cancelled

sub voice_once {
    my ($seconds) = @_; # undef: push to talk
    $VOICE_CANCELLED = 0;
    my $dir = voice_dir() or return;
    my $file = "$dir/voice.wav";
    my $got;
    if(defined $seconds){
        print "${colors::cyan_color}[recording $seconds s]${colors::reset_color}\n";
        $got = voice_record($file, $seconds);
    } else {
        $got = voice_ptt($file);
    }
    if(defined $got and $got eq 'cancel'){
        $VOICE_CANCELLED = 1;
        unlink $file;
        print "${colors::cyan_color}[cancelled]${colors::reset_color}\n";
        return;
    }
    my $text;
    if($got and voice_quiet($file)){
        print "${colors::cyan_color}[nothing heard]${colors::reset_color}\n";
    } elsif($got){
        $text = transcribe($file);
    }
    unlink $file; # the speech is not kept on disk
    return unless defined $text and length $text;
    return $text;
}

sub one_shot {
    my ($prompt) = @_;
    $::LOOP  = 1;
    $::ABORT = 0;
    if(!defined $prompt or $prompt !~ m/\S/){
        log::error("no prompt");
        return 1;
    }
    start_status_line();
    local $SIG{INT} = sub {$::ABORT = 1};
    local $BUSY = 1;
    local $ONE_SHOT = 1; # one request and out: no compaction afterwards
    my $ok = eval {chat_completion($prompt)};
    if($@){
        log::error(${colors::red_color}.($@ =~ s/\s+\z//r).${colors::reset_color});
        return 1;
    }
    return 130 if utils::aborted();
    return $ok ? 0 : 1;
}

# tell readline how much of the screen is its own
sub fit_readline {
    return unless $::T and $TUI->bar();
    my ($rows, $cols) = $TUI->size()
        or return;
    eval {$::T->set_screen_size($rows - $TUI->{footer}, $cols)};
    return;
}

sub chat_loop {
    $::LOOP = 1;
    my $input_cli_sub = -t STDIN ? input_terminal() : input_stdin();
    start_status_line(bar => (-t STDIN ? 1 : 0));
    # Input from a pipe or file: there is no readline to catch the signals.
    # ctrl-C (INT) stops the turn that runs and the next line is read; a
    # second one while that is still stopping, or one while nothing runs,
    # ends the program. TERM always ends it, after the turn was stopped.
    local @SIG{qw(INT TERM)} = (sub {
        my ($sig) = @_;
        if($BUSY and !$::ABORT){
            $::ABORT = 1;
            $::LOOP  = 0 if $sig eq 'TERM';
            return;
        }
        cleanup_chat();
        exit($sig eq 'TERM' ? 143 : 130);
    }) x 2 unless -t STDIN;
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
    return unless $$ == $MAIN_PID; # never from a forked tool process
    $TUI->close() if $TUI;        # the whole screen scrolls again
    return unless $::T;
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
    ai::drop_empty_sessions() if $$ == $MAIN_PID;
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
    ai::agent_view("agent $self->{id}", "started: ".($task // ""));
    $ai::TUI->set("agent $self->{id}", sub {$self->status()});
    my $max = ai::max_agents();
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
    my $t = $self->{tokens} // 0;
    return "agent $self->{id}: $self->{activity}"
        .($self->{turns} ? ", turn $self->{turns}" : "")
        .($t >= 10_000 ? sprintf(", %dk tok", $t / 1000) : $t >= 1000 ? sprintf(", %.1fk tok", $t / 1000) : $t ? ", $t tok" : "");
}

sub start {
    my ($self) = @_;
    $RUNNING{$self->{id}} = $self;
    $self->save();
    $self->request();
    return;
}

sub request {
    my ($self) = @_;
    return $self->finish(undef, "interrupted") if utils::aborted();
    my $budget = $::ORIG_ENV{AI_TOKEN_BUDGET};
    return $self->finish(undef, "token budget used up (AI_TOKEN_BUDGET)")
        if $budget and (ai::load_usage()->{total_tokens} // 0) >= $budget;
    $self->compact();
    my $json = do {
        local $ai::SESSION_MODEL = $::ORIG_ENV{AI_AGENT_MODEL} || $ai::SESSION_MODEL;
        local $ai::IN_AGENT = 1; # no agent tool for an agent
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
            $info->{tool_calls} = ai::stream_tool_calls($st);
            $self->response($st->{content}, $err, $info);
        },
    );
    return;
}

sub response {
    my ($self, $resp, $err, $info) = @_;
    if(!defined $err or length($resp)){
        my ($in, $out) = ai::record_usage($self->{msgs}, $resp, $info);
        $self->{tokens} += $in + $out;
    }
    my $answer = ai::strip_thinking($resp) =~ s/\A\s+//r;
    if(defined $err){
        return $self->finish(undef, "interrupted") if utils::aborted();
        # too long for the model: make room, once, and ask again
        return $self->request()
            if $info->{context} and !length($answer) and !$self->{context_retry}++ and $self->compact(1);
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
    my $native = $info->{tool_calls} // []; # the calls the server made
    return $self->finish(undef, "the model gave no answer") unless length($answer) or @$native;
    my %m = (role => 'assistant', content => $answer);
    $m{tool_calls} = [map {+{id => $_->{id}, type => 'function',
        function => {name => $_->{name}, arguments => $_->{arguments}}}} @$native]
        if @$native;
    push @{$self->{msgs}}, \%m;
    $self->save();
    my @calls = @$native ? map {ai::native_call($_)} @$native : ai::parse_tool_calls(ai::to_bytes($answer));
    return $self->finish($answer) unless @calls;
    my $max_turns = $::ORIG_ENV{AI_AGENT_MAX_TURNS} // 20;
    return $self->finish($answer, "stopped after $max_turns tool turns (AI_AGENT_MAX_TURNS)")
        if $max_turns and ++$self->{turns} >= $max_turns;
    $self->{queue} = \@calls;
    $self->next_tool();
    return;
}

# Keep the conversation of the agent within the context window: when it is
# over the threshold (or $force), the output of its older tool calls is cut,
# and if that is not enough its oldest steps are dropped. The system prompt
# and the task always stay, so do the last two messages. No summary is asked
# for: an agent has one task and that is still there.
# Returns true when something was removed.
sub compact {
    my ($self, $force) = @_;
    my @m = @{$self->{msgs}};
    return 0 if @m <= 4;
    my $limit  = ai::context_limit();
    my $before = ai::estimate_tokens(@m);
    return 0 unless $force or ($limit and $before > $limit * ($::ORIG_ENV{AI_CONTEXT_THRESHOLD} // 0.8));
    my $target = int(($limit || $before) * 0.5);
    my @head = @m[0, 1];
    my @last = @m[-2, -1];
    my ($pruned, @mid) = ai::prune_tool_results(@m[2 .. $#m - 2]);
    my $dropped = 0;
    while(@mid and ai::estimate_tokens(@head, @mid, @last) > $target){
        shift @mid;
        $dropped++;
    }
    # what is kept starts with something the agent said
    while(@mid and ($mid[0]{role} // '') ne 'assistant'){
        shift @mid;
        $dropped++;
    }
    return 0 unless $pruned or $dropped;
    my @note = $dropped
        ? ({role => 'user', content => "[$dropped earlier steps of your work on this task were removed to save context. Go on from what follows.]"})
        : ();
    $self->{msgs} = [@head, @note, @mid, @last];
    $self->{compacted}++;
    log::info("agent $self->{id}: context ~$before -> ~".ai::estimate_tokens(@{$self->{msgs}})." tokens");
    return 1;
}

# run the tool calls of the last answer one after the other, then ask again
sub next_tool {
    my ($self) = @_;
    while(my $c = shift @{$self->{queue}}){
        my $got = sub {
            my ($result, $err) = @_;
            # a call of the server is answered with a tool message, as its API wants
            push @{$self->{msgs}}, $c->{id}
                ? {role => 'tool', tool_call_id => $c->{id}, content => ai::to_text($err // $result // '')}
                : {role => 'user', content => ai::to_text(ai::tool_response($c->{tool}, $result, $err))};
            $self->save();
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
        ai::agent_view("agent $self->{id}", ai::tool_summary($c));
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

# What the agent did, for whoever wants to know: sessions/<name>/agents/<n>.chat,
# rewritten after every message, so a stuck agent can still be read.
sub save {
    my ($self) = @_;
    eval {
        my $dir = "$ai::AI_SESSION_DIR/agents";
        -d $dir or mkdir $dir or die "$dir: $!\n";
        ai::spew(sprintf("%s/%d-%03d.chat", $dir, $^T, $self->{id}),
            join('', map {$::JSON->encode($_)."\n"} @{$self->{msgs}}));
        1;
    } or log::info("agent transcript not saved: $@");
    return;
}

sub finish {
    my ($self, $result, $err) = @_;
    return if $self->{done};
    @{$self}{qw(done result error activity)} = (1, $result, $err, 'done');
    delete $RUNNING{$self->{id}};
    $ai::TUI->unset("agent $self->{id}");
    $self->save();
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
        n_predict    => $::ORIG_ENV{AI_TOKENS}      // ai::default_tokens(),
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

# request headers for the API when they are not the usual ones (undef: use
# the default, Authorization with the key)
sub headers {
    return;
}

sub req {
    my (@jstr) = @_;
    my $model = $SESSION_MODEL || $::ORIG_ENV{AI_MODEL};
    my $req = {
        ($model ? (model => $model):()),
        max_tokens   => $::ORIG_ENV{AI_TOKENS}      // ai::default_tokens(),
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
    # the tools, natively: the server turns the model's calls into tool_calls
    $req->{tools} = tools::native_list(exclude => ($ai::IN_AGENT ? ['agent'] : []))
        if ai::native_calls();
    # the reasoning of the model, when it is set (/thinking, AI_THINKING)
    if(defined(my $th = ai::thinking_setting())){
        $req->{chat_template_kwargs} = {enable_thinking => $th eq 'off' ? $Types::Serialiser::false : $Types::Serialiser::true};
        $req->{reasoning_budget} = $th + 0 if $th =~ m/^\d+$/;
    }

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
    # thinking on unless the session or AI_THINKING says otherwise (provider::req)
    $req->{chat_template_kwargs} //= {"enable_thinking" => $Types::Serialiser::true};
    # the answer limit of the API for this model, 16384 (AI_TOKENS overrides)
    $req->{max_tokens} = $::ORIG_ENV{AI_TOKENS} // 16384;
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

package provider::flm;

use strict; use warnings;
use base qw(provider);

*req = *provider::req;
*raw = *provider::raw;

package provider::lemonade;

use strict; use warnings;
use base qw(provider);

*req = *provider::req;
*raw = *provider::raw;


package provider::openai;

use strict; use warnings;
use base qw(provider);

*raw = *provider::raw;

# the newer models want max_completion_tokens, take no top_k/min_p, and only
# the default temperature and top_p unless AI_TEMPERATURE/AI_TOP_P say otherwise
sub req {
    my (@jstr) = @_;
    my $req = provider::req(@jstr);
    $req->{max_completion_tokens} = delete $req->{max_tokens};
    delete $req->{$_} for qw(top_k min_p chat_template_kwargs reasoning_budget);
    delete $req->{temperature} unless defined $::ORIG_ENV{AI_TEMPERATURE};
    delete $req->{top_p} unless defined $::ORIG_ENV{AI_TOP_P};
    return $req;
}

package provider::anthropic;

use strict; use warnings;
use base qw(provider);

# Messages API: the system prompt is a field of its own, the answer streams as
# content_block_delta events (see ai::new_stream). Its tools are not used:
# the tool calls are written in the text, as with every other provider.
sub headers {
    my ($key) = @_;
    return [
        "Accept: application/json",
        "Content-Type: application/json",
        "User-Agent: AI Chat/0.1",
        "x-api-key: $key",
        "anthropic-version: 2023-06-01",
    ];
}

sub req {
    my (@msgs) = @_;
    my (@system, @chat);
    for my $m (@msgs) {
        if($m->{role} eq 'system'){
            push @system, $m->{content};
            next;
        }
        # the API wants alternating roles: consecutive ones are joined
        if(@chat and $chat[-1]{role} eq $m->{role}){
            $chat[-1]{content} .= "\n\n".$m->{content};
        } else {
            push @chat, {role => $m->{role}, content => $m->{content}};
        }
    }
    my $req = {
        model       => $SESSION_MODEL || $::ORIG_ENV{AI_MODEL} || 'claude-sonnet-5-5',
        max_tokens  => $::ORIG_ENV{AI_TOKENS} // 8192, # required by the API
        temperature => $::ORIG_ENV{AI_TEMPERATURE} // 0.6,
        top_k       => $::ORIG_ENV{AI_TOP_K} // 20,
        stream      => $Types::Serialiser::true,
        messages    => \@chat,
    };
    $req->{system} = join("\n\n", @system) if @system;
    return $req;
}

# no raw completion for this API: build_request() gives its error
sub raw {
    return;
}

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
    } grep {!$exclude{$_} and tools::available($_)} sort keys %{$tools::TOOLS});
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
    find => {
        description => "find files and directories under a path: the entries whose name matches a Perl regular expression (all of them when empty), with their path, sorted. Symbolic links are listed, never followed. Up to 1000 results",
        syntax => "///FIND_f1e0+EO_b2c4+EO_d8a5\n{{path}}\nEO_b2c4[LENGTH({{path}})]\n{{name}}\nEO_d8a5[LENGTH({{name}})]\nFIND_f1e0",
        properties  => {
            "path" => {type => "string", description => "The directory to search, . for the current one"},
            "name" => {type => "string", description => "A Perl regular expression for the name, such as \\.pm\$ (empty for all)"},
        },
        required => ["path", "name"],
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
        # not on FastFlowLM: the NPU runs one request at a time and is kept for voice
        available => sub {!ai::provider_is('flm')},
    },
    fetch => {
        description => "get a web page or file by its URL (http or https). HTML comes back as text, with links as [text](url)",
        syntax => "///FETCH_6e1b+EO_c93a\n{{url}}\nEO_c93a[LENGTH({{url}})]\nFETCH_6e1b",
        properties  => {
            "url" => {type => "string", description => "The URL"},
        },
        required => ["url"],
    },
    search => {
        description => "search the web: gives titles, URLs and a line of text for the best results. Use 'fetch' to read one",
        syntax => "///SEARCH_d4a7+EO_15be\n{{query}}\nEO_15be[LENGTH({{query}})]\nSEARCH_d4a7",
        properties  => {
            "query" => {type => "string", description => "What to search for"},
        },
        required => ["query"],
        # only with a SearXNG instance to ask
        available => sub {length($::ORIG_ENV{AI_SEARXNG_URL} // '') ? 1 : 0},
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
    # the /// is optional, and so is a code fence before the header: a model that
    # writes its call in a fence gets it run, not dropped
    $TOOLS_RX = '^[ \t]*(?:`{3}[^\n]*\n[ \t]*)?(?:///)?('.join('|', sort @tags).')((?:\+\w+)*)[ \t]*\n';
}

sub rx {
    $TOOLS_RX;
}

# the arguments of a tool, in the order of its syntax: {{path}}, {{content}}, ...
sub arg_names {
    my ($t) = @_;
    # each argument shows up twice in a syntax (its length in a sentinel, then
    # its text): keep the first place of each, in order
    my (%seen, @names);
    while ($t->{syntax} =~ m/\{\{(\w+)\}\}/g){
        push @names, $1 unless $seen{$1}++;
    }
    return @names;
}

# the tools as the API takes them natively (OpenAI style "tools" of a request):
# the same names and descriptions as the text syntax, sorted so that the
# request stays the same from one call to the next
sub native_list {
    my (%o) = @_;
    my %exclude = map {($_ => 1)} @{$o{exclude} // []};
    my @list;
    foreach my $k (sort keys %$TOOLS){
        next if $exclude{$k} or !available($k);
        my $t = $TOOLS->{$k};
        push @list, {type => 'function', function => {
            name        => $k,
            description => $t->{description},
            parameters  => {
                type       => 'object',
                properties => $t->{properties},
                required   => $t->{required} // [],
            },
        }};
    }
    return \@list;
}

# the arguments (an arrayref, bytes, in the order of the syntax) of a native
# call, from its JSON arguments; undef when they do not fit the tool
sub native_args {
    my ($name, $json) = @_;
    my $t = $TOOLS->{lc $name} or return;
    my $in = eval {$::JSON->decode(length($json // '') ? $json : '{}')};
    return unless ref($in) eq 'HASH';
    my %required = map {($_ => 1)} @{$t->{required} // []};
    my @args;
    foreach my $a (arg_names($t)){
        my $v = $in->{$a};
        if(!defined $v or ref($v)){
            return if $required{$a};
            $v = '';
        }
        push @args, ai::to_bytes("$v");
    }
    return \@args;
}

# is a tool there to be used (and to be told about in the prompt)
sub available {
    my ($name) = @_;
    my $t = $TOOLS->{$name}
        or return 0;
    return $t->{available} ? ($t->{available}->() ? 1 : 0) : 1;
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

# An HTTP request of a tool, in the event loop: waited for by the main agent,
# a job for a sub-agent (like _run for children). $finish gets the request
# when it is over and returns the result or dies. Web tools have their own
# proxy (utils::proxy_for('web')), not the one of the LLM API.
sub _http {
    my ($finish, %req) = @_;
    $req{proxy}   = utils::proxy_for('web') // '' unless exists $req{proxy};
    $req{timeout} //= $::ORIG_ENV{AI_WEB_TIMEOUT} // 30;
    $req{connect_timeout} //= 10;
    $req{follow}  //= 5;
    $req{max_size} //= $::ORIG_ENV{AI_WEB_MAX_SIZE} // 2_000_000;
    $req{headers} //= [
        "User-Agent: ".($::ORIG_ENV{AI_WEB_USER_AGENT} // "Mozilla/5.0 (compatible; aicli)"),
        "Accept: text/html,application/xhtml+xml,application/json,text/plain;q=0.9,*/*;q=0.5",
        "Accept-Language: ".($::ORIG_ENV{AI_WEB_LANGUAGE} // "en"),
    ];
    my $start = sub {
        my ($done) = @_;
        loop::http(%req, on_done => $done);
    };
    return bless({start => $start, finish => $finish}, 'tools::job')
        if $ASYNC;
    my ($over, $r);
    &{$start}(sub {($r, $over) = ($_[0], 1)});
    loop::run(sub {$over});
    return &{$finish}($r);
}

# what went wrong with a web request, dies; a body cut at max_size is fine
sub _http_check {
    my ($r) = @_;
    return if !defined $r->{error} or $r->{too_big};
    my $body = $r->{body} // '';
    $body =~ s/\s+/ /g;
    die "$r->{error}".($r->{code} ? "" : " ($r->{url})").(length($body) ? ": ".substr($body, 0, 300) : "")."\n";
}

# fetch: a page of the web as text
sub fetch_6e1b {
    my ($t_args) = @_;
    my $url = utils::trim($t_args->[0] // '');
    $url = "https://$url" if $url =~ m{^[\w.-]+\.[a-z]{2,}(?:[/:?]|$)}i and $url !~ m{^\w+://};
    die "need an http or https URL\n" unless $url =~ m{^https?://[^\s/]+}i and $url !~ m/\s/;
    return _http(sub {
        my ($r) = @_;
        _http_check($r);
        my $type = $r->{headers}{'content-type'} // '';
        die "not a text: $type\n"
            if $type =~ m{^\s*(?:image|audio|video|font)/|application/(?:octet-stream|pdf|zip|gzip|x-tar)}i;
        my $body = $r->{body};
        $body = ai::html_to_text($body, $type)
            if $type =~ m/html/i or (!length($type) and $body =~ m/\A\s*<(?:!doctype|html)\b/i);
        return "URL: $r->{url_final}\n\n$body"
            .($r->{too_big} ? "\n[... cut here, there is more than $r->{max_size} bytes ...]\n" : "");
    }, url => $url);
}

# search: ask a SearXNG instance (AI_SEARXNG_URL), it must allow format=json.
# It is yours and near: no proxy, unless AI_SEARXNG_PROXY says so.
sub search_d4a7 {
    my ($t_args) = @_;
    my $query = utils::trim($t_args->[0] // '') =~ s/\s+/ /gr;
    die "no query\n" unless length($query);
    my $base = $::ORIG_ENV{AI_SEARXNG_URL} // '';
    die "no search engine is set up (AI_SEARXNG_URL)\n" unless length($base);
    $base =~ s{/+\z}{};
    $base =~ s{/search\z}{};
    my $proxy = $::ORIG_ENV{AI_SEARXNG_PROXY} // '';
    $proxy = '' if $proxy =~ m/^(?:none|off|direct|no)$/i;
    my $max = $::ORIG_ENV{AI_SEARCH_RESULTS} // 8;
    my $q = $query =~ s/([^A-Za-z0-9_.~-])/sprintf("%%%02X", ord($1))/ger;
    return _http(sub {
        my ($r) = @_;
        die "the search engine refuses format=json, enable it in the SearXNG settings (search: formats: [html, json])\n"
            if $r->{code} == 403;
        _http_check($r);
        my $data = eval {JSON::XS->new->utf8->decode($r->{body})};
        die "the search engine did not answer with JSON\n" unless ref($data) eq 'HASH';
        my @results = grep {ref($_) eq 'HASH' and length($_->{url} // '')} @{$data->{results} // []};
        return "no results for: $query\n" unless @results;
        splice(@results, $max) if $max and @results > $max;
        my $n = 0;
        return join("\n", map {
            my ($title, $text) = map {($_ // '') =~ s/\s+/ /gr =~ s/^ | $//gr} $_->{title}, $_->{content};
            $text = substr($text, 0, 300)."..." if length($text) > 300;
            ai::to_bytes(++$n.". $title\n   $_->{url}\n".(length($text) ? "   $text\n" : ""));
        } @results);
    }, url => "$base/search?q=$q&format=json", proxy => $proxy, follow => 2,
       headers => ["Accept: application/json", "User-Agent: aicli"]);
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
    my ($fh, $fn) = File::Temp::tempfile("aicli_bash_XXXXXXXX", DIR => ai::tmpdir());
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
    return _slurp(_path($t_args->[0]));
}

sub write_edf5 {
    my ($t_args) = @_;
    my $path = _path($t_args->[0]);
    log::info("WRITE: $path");
    die "is a directory: $path\n" if -d $path;
    _changing($path, 'write', $t_args->[1] // '');
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

# Where a path really leads, as an absolute path without links, "." and "..".
# Done here, name by name: a symbolic link (readlink) is replaced by what it
# points to, ".." drops the name before it. That is text work on names that
# were each looked at, never a pattern over the whole path: a pattern cannot
# see links. What does not exist is taken as the name it is, so this also
# says where a new file would be, or where a link to nowhere points.
# With $nofollow the last name stays itself, link or not.
sub _resolve {
    my ($path, $nofollow) = @_;
    utils::load_cpan("File::Spec");
    my @todo = grep {length and $_ ne '.'} split m{/+}, File::Spec->rel2abs($path);
    my (@done, $links);
    while(@todo){
        my $name = shift @todo;
        if($name eq '..'){
            pop @done; # @done has no links: the name before is the parent
            next;
        }
        my $here = '/'.join('/', @done, $name);
        if(-l $here and !($nofollow and !@todo)){
            die "too many symbolic links: $path\n" if ++$links > 40;
            my $target = readlink($here) // die "cannot read the link $here: $!\n";
            @done = () if $target =~ m{\A/};
            unshift @todo, grep {length and $_ ne '.'} split m{/+}, $target;
            next;
        }
        push @done, $name;
    }
    return '/'.join('/', @done);
}

# The workspace: the file tools only touch what is inside $ai::WORKSPACE (and
# the directories of AI_WORKSPACE_ALLOW). Returns the path as given (trimmed)
# when it is inside, dies otherwise. What counts is where the path really
# leads (_resolve): a link in the workspace that points out of it is outside.
# With nofollow the last part is taken as the entry itself, not what it links
# to (delete, move).
# This holds the file tools back, not bash or perl: for those the container
# is the fence.
sub _path {
    my ($path, %o) = @_;
    $path = utils::trim($path // '');
    $path = $o{default} if !length($path) and defined $o{default};
    my $root = $ai::WORKSPACE;
    return $path unless defined $root and length($path);
    my $outside = "outside of the workspace ($root): $path\n";
    die $outside if $o{nofollow} and $path =~ m{(?:\A|/)\.\.?/*\z};
    my $real = eval {_resolve($path, $o{nofollow})} // die $outside;
    foreach my $ok ($root, @ai::WORKSPACE_ALLOW){
        return $path if $ok eq '/' or $real eq $ok or index($real, "$ok/") == 0;
    }
    die $outside;
}

our @CHANGES; # file contents changed by the last tools: {tool, path, old, new}
our $UNDO_SEQ = 0;

# Remember how to take a file change back: a line in the undo journal of the
# session, with a copy of what is about to be lost. See ai::undo_last.
sub _journal {
    my (%e) = @_;
    my $dir = $ai::AI_SESSION_DIR;
    return unless defined $dir and -d $dir;
    eval {
        $dir .= "/undo";
        -d $dir or mkdir $dir or die "$dir: $!\n";
        utils::load_cpan("File::Spec");
        $e{$_} = File::Spec->rel2abs($e{$_}) for grep {defined $e{$_}} qw(path to);
        if(defined(my $old = delete $e{old})){
            if(length($old) <= ($::ORIG_ENV{AI_UNDO_MAX_SIZE} // 8_000_000)){
                $e{backup} = sprintf("%d-%d-%04d", time(), $$, ++$UNDO_SEQ);
                ai::spew("$dir/$e{backup}", $old);
            }
            $e{mode} = (stat($e{path}))[2];
            $e{existed} = 1;
        }
        open(my $fh, '>>', "$dir/journal") or die "$dir/journal: $!\n";
        print {$fh} JSON::XS->new->utf8->canonical->encode(\%e)."\n";
        close($fh);
        1;
    } or log::info("undo journal: $@");
    return;
}

# a file is about to get new content
sub _changing {
    my ($file, $tool, $new) = @_;
    my $old = (-f $file) ? _slurp($file) : undef;
    _journal(op => 'write', tool => $tool, path => $file, old => $old);
    push @CHANGES, {tool => $tool, path => $file, old => $old, new => $new};
    return;
}

# write through a temp file and rename: all of it or nothing, mode kept
sub _spew {
    my ($file, $content, $tool) = @_;
    _changing($file, $tool // 'write', $content);
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
    my $file  = _path($t_args->[0]);
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
    my $file = _path($t_args->[0]);
    my ($old, $new) = ($t_args->[1] // '', $t_args->[2] // '');
    die "the old text is empty\n" unless length($old);
    my $content = _slurp($file);
    my $count = () = $content =~ m/\Q$old\E/g;
    die "the old text is not in $file, mind the exact whitespace\n" unless $count;
    die "the old text is $count times in $file, add lines around it to make it unique\n" if $count > 1;
    my $at = index($content, $old);
    substr($content, $at, length($old)) = $new;
    _spew($file, $content, 'replace');
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
    my $file = _path($t_args->[0]);
    my $old  = _slurp($file);
    my $new  = ed_apply($old, $t_args->[1]);
    return "[OK] no change in $file" if $new eq $old;
    _spew($file, $new, 'edit');
    return "[OK] edited $file: ".($old =~ tr/\n//)." -> ".($new =~ tr/\n//)." lines";
}

sub delete_5d2a {
    my ($t_args) = @_;
    my $path = _path($t_args->[0], nofollow => 1);
    die "no path\n" unless length($path);
    if(-d $path and !-l $path){
        rmdir($path)
            or die "cannot remove directory $path: $!\n";
        _journal(op => 'rmdir', tool => 'delete', path => $path);
        return "[OK] removed directory $path";
    }
    die "no such file: $path\n" unless -e $path or -l $path;
    _journal(op => 'delete', tool => 'delete', path => $path, old => ((-f $path and !-l $path) ? _slurp($path) : undef));
    unlink($path)
        or die "cannot delete $path: $!\n";
    return "[OK] deleted $path";
}

sub move_c7f0 {
    my ($t_args) = @_;
    my $from = _path($t_args->[0], nofollow => 1);
    my $to   = _path($t_args->[1]);
    die "need two paths\n" unless length($from) and length($to);
    die "no such file: $from\n" unless -e $from or -l $from;
    $to = _path("$to/".($from =~ s{.*/}{}r), nofollow => 1) if -d $to;
    die "$to exists already\n" if -e $to or -l $to;
    if(!rename($from, $to)){
        # another filesystem
        utils::load_cpan("File::Copy");
        File::Copy::move($from, $to)
            or die "cannot move $from to $to: $!\n";
    }
    _journal(op => 'move', tool => 'move', path => $from, to => $to);
    return "[OK] moved $from to $to";
}

sub mkdir_2e9b {
    my ($t_args) = @_;
    my $path = _path($t_args->[0]);
    die "no path\n" unless length($path);
    return "[OK] $path exists already" if -d $path;
    utils::load_cpan("File::Path");
    my @created = File::Path::make_path($path, {error => \my $err});
    utils::load_cpan("File::Spec");
    _journal(op => 'mkdir', tool => 'mkdir', path => $path, created => [map {File::Spec->rel2abs($_)} @created]) if @created;
    die "cannot create $path: ".join(", ", map {values %$_} @$err)."\n" if @$err;
    return "[OK] created $path";
}

sub list_a41d {
    my ($t_args) = @_;
    my $path = _path($t_args->[0], default => '.');
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

# walk_tree: a directory tree with opendir/readdir (no File::Find, no glob).
# $filter->($shown, $name, $is_dir, $is_link) decides which entries are
# results; $shown is the path as joined from $label, the start as it was given.
# $prune->($shown, $name) true means: do not go into that directory. Symbolic
# links are listed but never followed, so the walk stays where the start is.
# Entries are sorted within each directory. Options: depth (levels below the
# start, default unlimited), max (results, default 1000). Returns the results,
# whether more matched than max, and the number of directories not readable.
sub walk_tree {
    my ($start, $label, %o) = @_;
    my $filter = $o{filter} // sub {1};
    my $prune  = $o{prune}  // sub {0};
    my $max    = $o{max}    // 1000;
    my ($found, $more, $unreadable) = ([], 0, 0);
    my $visit;
    $visit = sub {
        my ($dir, $shown_dir, $level) = @_;
        opendir(my $dh, $dir) or do {$unreadable++; return};
        my @names = sort grep {$_ ne '.' and $_ ne '..'} readdir($dh);
        closedir($dh);
        foreach my $name (@names){
            my $path   = "$dir/$name";
            my $shown  = "$shown_dir/$name";
            my $link   = -l $path ? 1 : 0;
            my $is_dir = (!$link and -d $path) ? 1 : 0;
            if($filter->($shown, $name, $is_dir, $link)){
                if(@$found >= $max){
                    $more = 1;
                    return;
                }
                push @$found, $shown;
            }
            next unless $is_dir;
            next if defined $o{depth} and $level >= $o{depth};
            next if $prune->($shown, $name);
            $visit->($path, $shown, $level + 1);
            return if $more;
        }
    };
    $visit->($start, $label, 1);
    undef $visit; # the closure refers to itself
    return ($found, $more, $unreadable);
}

# find: the entries under a directory whose name matches a regex
sub find_f1e0 {
    my ($t_args) = @_;
    my $path = _path($t_args->[0], default => '.');
    $path = '.' unless length($path);
    die "not a directory: $path\n" unless -d $path;
    my $name = utils::trim($t_args->[1] // '');
    my $re;
    if(length $name){
        $re = eval {qr/$name/};
        die "bad name pattern '$name'\n" unless $re;
    }
    my ($found, $more, $unreadable) = walk_tree($path, $path,
        filter => sub {!$re or $_[1] =~ $re});
    my $out = join('', map {"$_\n"} @$found);
    $out .= "more matches than 1000: use a narrower name or a deeper path\n" if $more;
    $out .= "$unreadable director".($unreadable == 1 ? 'y' : 'ies')." could not be read\n" if $unreadable;
    return length($out) ? $out : "no matches\n";
}

# grep: a forked child exec()s grep, no shell involved
sub grep_6629 {
    my ($t_args) = @_;
    my $path    = _path($t_args->[0]);
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
our $think_color  = "\033[38;5;136m"; # thinking: a darker gold than the yellow of the tool lines
our $blue_color1   = "\033[0;34m";
our $blue_color2   = "\033[38;5;25;1m";
our $blue_color3   = "\033[38;5;13;1m";
our $magenta_color = "\033[0;35m";
our $cyan_color    = "\033[0;36m";
our $white_color   = "\033[0;37m";
our $reset_color   = "\033[0m";
}

1;
