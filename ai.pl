#!/usr/bin/perl

use strict;
use warnings;

use FindBin;

# don't leak ENV to other forks, clear $0 asap: clears envp
my $orig_dollar0;
my %ORIG_ENV;
BEGIN {
    %ORIG_ENV = %ENV;
    %ENV = ();
    $orig_dollar0 = $0;
    $0 = "aicli";
}

use Getopt::Long;
use Socket;
use Cwd qw();
use Encode qw(_utf8_on _utf8_off);

# Command-line options
my $DEBUG = $ORIG_ENV{DEBUG} // 0;
my $help;
GetOptions(
    'help|?' => \$help,
    'debug'  => \$DEBUG,
) or show_usage();

show_usage() if $help;

# init/setup
my $BASE_DIR = $ORIG_ENV{AI_DIR} // (glob('~/.aicli'))[0];
-d "$BASE_DIR"
    or mkdir $BASE_DIR
    or die "Failed to create $BASE_DIR: $!\n";
my $SESSIONS_DIR = "$BASE_DIR/sessions";
-d $SESSIONS_DIR
    or mkdir $SESSIONS_DIR
    or die "Failed to create $SESSIONS_DIR: $!\n";
my $CONFIG_FILE = $ORIG_ENV{AI_CONFIG}
    // "$BASE_DIR/config";
my $AI_PROMPT_TEMPLATE = $ORIG_ENV{AI_PROMPT_TEMPLATE}
    // 'default';
my $AI_PROMPT_TEMPLATE_FILE = $ORIG_ENV{AI_PROMPT_TEMPLATE_FILE}
    // "$FindBin::Bin/ai/$AI_PROMPT_TEMPLATE";
my $AI_SESSION = $ORIG_ENV{AI_SESSION}
    // $ORIG_ENV{AI_PROMPT_DEFAULT};
if (!$AI_SESSION) {
    # Generate a UUID for default session
    eval {load_cpan("Data::UUID")};
    if ($@) {
        log_error("Please install Data::UUID module to generate UUIDs");
        exit 1;
    }
    my $ug = Data::UUID->new();
    $AI_SESSION = "session-" . $ug->create_str();
}
my $AI_SESSION_DIR = "$SESSIONS_DIR/$AI_SESSION";
-d $AI_SESSION_DIR
    or mkdir $AI_SESSION_DIR
    or die "Failed to create $AI_SESSION_DIR: $!\n";
my $HISTORY_FILE = "$AI_SESSION_DIR/history";
my $PROMPT_FILE  = "$AI_SESSION_DIR/prompt";
my $STATUS_FILE  = "$AI_SESSION_DIR/chat";

# Variables/Handles
our ($api_key, $curl_handle, $ai_endpoint_url, $SESSION_MODEL, $provider_name, $v1_prefix);
load_cpan("JSON::XS");
my $json //= JSON::XS->new->utf8->allow_blessed->allow_unknown->allow_nonref->convert_blessed;

# Define available tools for the AI system prompt
my $TOOLS = {
    bash => {
        description => "Execute an arbitrary shell script",
        syntax => "\n///BASH_7c48+EO_dfd7e6b99d1bf15480fa\n{{code}}\nEO_dfd7e6b99d1bf15480fa\nBASH_7c48\n",
        parameters  => [
            {name => "code", required => 1, type => "string", description => "The bash code to execute"},
        ]
    },
    perl => {
        description => "Execute a perl script",
        syntax => "\n///PERL_d8d2+EO_929b2e8d61111fac138f\n{{code}}\nEO_929b2e8d61111fac138f\nPERL_d8d2",
        parameters  => [
            {name => "code", required => 1, type => "string", description => "The perl code to execute"},
        ]
    },
    read => {
        description => "Read a file contents",
        syntax => "\n///READ_c5a3+EO_d0f15b09ea7648f828e7\n{{path}}\nEO_d0f15b09ea7648f828e7\nREAD_c5a3",
        parameters  => [
            {name => "{{path}}", required => 1, type => "string", description => "The path to the file"},
        ]
    },
    write => {
        description => "Write or overwrite a file's contents",
        syntax => "\n///WRITE_edf5+EO_d0684c052bf3d9c503a8+EO_ecdeef376b1647fa824a\n{{path}}\nEO_d0684c052bf3d9c503a8\n{{content}}\nEO_ecdeef376b1647fa824a\nWRITE_edf5",
        parameters  => [
            {name => "{{path}}"  , requided => 1, type => "string", description => "The path to the file"         },
            {name => "{{content" , requided => 1, type => "string", description => "The raw text content to write"}
        ]
    },
    grep => {
        description => "Search file with a regex pattern using PERL grep",
        syntax => "\n///GREP_6629+EO_a575a5c230c77d451640+EO_aaddf906cba61ec85a13\n{{path}}\nEO_a575a5c230c77d451640\n{{regex}}\nEO_aaddf906cba61ec85a13\nGREP_6629",
        parameters  => [
            {name => "{{path}}"  , required => 1, type => "string", description => "The file path or directory to scan" },
            {name => "{{regex}}" , required => 1, type => "string", description => "The PERL regular expression pattern"},
        ]
    },
};

# Main execution
our $cmds;
chat_setup();
setup_commands();
chat_loop();
exit 0;

sub show_usage {
    local $ENV{PAGER} = $ENV{PAGER} // 'less';
    local $0 = $orig_dollar0;
    load_cpan("FindBin")->again();
    load_cpan("Pod::Usage")->pod2usage(2);
    exit 0;
}

sub load_cpan {
    my ($module) = @_;
    eval "require $module";
    die $@ if $@;
    return $module;
}

sub chat_setup {
    if (!-f $CONFIG_FILE) {
        log_error("Please set AI_DIR/AI_CONFIG/AI_API_KEY environment variable or set $BASE_DIR/config");
        exit 1;
    } else {
        open(my $fh, ". $CONFIG_FILE; set|")
            or die "Failed to read $CONFIG_FILE: $!\n";
        my %envs = map { chomp; split m/=/, $_, 2 } grep m/^AI_/, <$fh>;
        while (my ($key, $value) = each %envs) {
            $ORIG_ENV{$key} //= $value =~ s/^['"]//r =~ s/['"]$//r;
        }
        close $fh;
    }

    # Get model for this session
    my $model_file = "$AI_SESSION_DIR/model";
    if(open(my $mfh, '<', $model_file)){
        $SESSION_MODEL = <$mfh>;
        $SESSION_MODEL ||= $ORIG_ENV{AI_MODEL};
        $SESSION_MODEL =~ s/^['"]//;
        $SESSION_MODEL =~ s/['"]$//;
        $SESSION_MODEL =~ s/\s+$//;
        $SESSION_MODEL =~ s/^\s+//;
        chomp $SESSION_MODEL;
        close $mfh;
    }
    $SESSION_MODEL ||= $ORIG_ENV{AI_MODEL};

    my %PROVIDERS = (
        'cerebras' => {
            url => 'https://api.cerebras.ai',
            key_prefix => 'csk-',
        },
        'openrouter' => {
            url => 'https://openrouter.ai/api',
            key_prefix => 'sk-or-',
        },
        'openai' => {
            url => 'https://api.openai.com/v1',
            key_prefix => 'sk-',
        },
        'groq' => {
            url => 'https://api.groq.com/openai/v1',
            key_prefix => 'gsk_',
        },
        'anthropic' => {
            url => 'https://api.anthropic.com/v1',
            key_prefix => 'sk-ant-',
        },
        'bedrock' => {
            url => 'https://bedrock-runtime.us-east-1.amazonaws.com',
            key_prefix => 'AKIA',  # AWS access key
        },
        'lemonade' => {
            url => 'http://localhost:8000/v1',
            key_prefix => '',
        },
    );

    $provider_name = lc($ORIG_ENV{AI_PROVIDER} // '');

    # Check for local llama.cpp server
    if ($ORIG_ENV{AI_LOCAL_SERVER}) {
        $ai_endpoint_url = $ORIG_ENV{AI_LOCAL_SERVER};
        $provider_name = undef;  # Don't set provider_name for local servers to avoid lookups
    } else {
        # Detect provider by key prefix or use configured provider
        my $detected_provider;
        if (defined $api_key && length($api_key)) {
            for my $name (keys %PROVIDERS) {
                if ($api_key =~ m/^$PROVIDERS{$name}{key_prefix}/) {
                    $detected_provider = $name;
                    last;
                }
            }
        }


        # Use detected provider or fall back to configured provider
        if ($provider_name and exists $PROVIDERS{$provider_name}) {
            $ai_endpoint_url = $PROVIDERS{$provider_name}{url};
        } elsif ($detected_provider) {
            $ai_endpoint_url = $PROVIDERS{$detected_provider}{url};
        } else {
            log_error("Unable to detect provider from API key. Set AI_PROVIDER environment variable");
            log_error("Supported providers: ".join(', ', keys %PROVIDERS));
            exit 1;
        }
        $api_key = $ORIG_ENV{AI_API_KEY};
        if (!$api_key) {
            log_error("Please set AI_API_KEY environment variable or set $BASE_DIR/config");
            exit 1;
        }
        if ($provider_name) {
            $v1_prefix = $provider_name eq 'anthropic' ? '' : 'v1/';
        } else {
            $v1_prefix = 'v1/';
        }
    }

    # Normalize URL - ensure it doesn't end with / for some endpoints
    $ai_endpoint_url =~ s|/+$||;
    init_session($AI_SESSION);
    return;
}

sub log_info {
    my ($message) = @_;
    return unless $DEBUG;
    my $LOG_FILE = $ORIG_ENV{AI_LOG} // "&STDOUT";
    my $lfh;
    open($lfh, ">>$LOG_FILE") or open($lfh, ">&STDERR") or return;
    print {$lfh} "INFO: [$$]: ".scalar(localtime()).": $message\n";
    close $lfh or die "Failed to close dup/file $LOG_FILE: $!\n";
    return;
}

sub log_error {
    my ($message) = @_;
    return unless $DEBUG;
    my $LOG_FILE = $ORIG_ENV{AI_LOG} // "&STDOUT";
    my $lfh;
    open($lfh, ">>$LOG_FILE") or open($lfh, ">&STDERR") or return;
    print {$lfh} "ERROR: [$$]: ".scalar(localtime()).": $message\n";
    close $lfh or die "Failed to close dup/file $LOG_FILE: $!\n";
    return;
}

sub chat_completion {
    my ($input) = @_;
    log_info("User input: $input");

    # Get current messages, add user message
    open(my $fh_read, '<', $STATUS_FILE)
        or die "Failed to read $STATUS_FILE: $!\n";
    my @jstr = do {map {chomp; JSON::XS::decode_json($_)} <$fh_read>};
    close $fh_read;
    push @jstr, {role => 'user', content => $input};

    my $req = {
        model       => $SESSION_MODEL || $ORIG_ENV{AI_MODEL} // 'llama-4-scout-17b-16e-instruct',
        max_tokens  => $ORIG_ENV{AI_TOKENS} // 8192,
        stream      => 1,
        messages    => \@jstr,
        temperature => $ORIG_ENV{AI_TEMPERATURE} // 0,
        top_p       => 1
    };

    # Provider-specific options
    $req->{provider} = {only => ["Cerebras"]} if ($provider_name//'') eq 'openrouter';
    log_info($json->encode($req));
    log_info("Requesting completion from AI API $ai_endpoint_url with ".($api_key//'<no api key>'));

    my $raw = http("post", "v1/chat/completions", $json->encode($req));
    if(!$raw){
        log_error("No response from API");
        return;
    }

    # Variable to hold the assembled assistant message
    my $assistant_text = '';

    if ($ORIG_ENV{AI_STREAM} // 0){
        # Parse Server-Sent Events (SSE) stream
        foreach my $event (split /\n\n/, $raw) {
            next unless $event =~ s/^data:\s*//;
            if ($event eq '[DONE]') { last; }
            eval {
                my $decoded = JSON::XS->new->utf8->decode($event);
                my $delta = '';
                if (exists $decoded->{choices}[0]{delta}{content}) {
                    $delta = $decoded->{choices}[0]{delta}{content};
                } elsif (exists $decoded->{choices}[0]{message}{content}) {
                    $delta = $decoded->{choices}[0]{message}{content};
                }
                if (defined $delta && length($delta)) {
                    _utf8_off($delta);
                    print $delta;
                    $assistant_text .= $delta;
                }
            };
            log_info("Failed to decode SSE event: $event, error: $@") if $@;
        }
    } else {
        # Non‑streaming response (original behaviour)
        my $decoded = JSON::XS->new->utf8->decode($raw);
        unless (exists $decoded->{choices}[0]{message}{content}) {
            log_error("Failed to parse response");
            return;
        }
        $assistant_text = $decoded->{choices}[0]{message}{content};
    }

    # Re‑use the existing tool‑call processing logic on the assembled text
    my $resp = $assistant_text;   # reuse variable name expected by downstream code

     # Process tool calls in the AI response - FIXED VERSION
    my @new_turns;  # Collect message turns to add
    my $pos = 0;

    while ($resp =~ m{/(\w+)\s+([^\n]+)}g) {
        my $tool = $1;
        my $args = $2;
        next unless exists $TOOLS->{$tool};

        # Extract assistant text BEFORE this tool call
        if (pos($resp) > length($args) + 2 + length($tool)) {  # "/tool " prefix
            my $assistant_text_sub = substr($resp, $pos, pos($resp) - length($args) - 2 - length($tool));
            if (length($assistant_text_sub)) {
                push @new_turns, {role => 'assistant', content => $assistant_text_sub};
            }
        }

        log_info("Tool call detected: $tool with args: $args");
        log_info("${colors::yellow_color1}Executing tool: /$tool $args${colors::reset_color}\n");

        my $result = execute_tool($tool, $args);
        if ($result) {
            my $tool_response = "[TOOL RESULT from $tool: $result]";
            push @new_turns, {role => 'user', content => $tool_response};
            log_info("Sending tool result back to AI: $tool_response");
        }

        $pos = pos($resp);  # Update position for next iteration
    }

    # Add any remaining text after last tool call as final assistant message
    if (defined $resp and (pos($resp)//0) < length($resp)) {
        my $remaining_text = substr($resp, (pos($resp)//0));
        push @new_turns, {role => 'assistant', content => $remaining_text} if length($remaining_text);
    } elsif (!@new_turns) {
        push @new_turns, {role => 'assistant', content => $resp};
    }

    _utf8_off($resp);

    # Output and save the new conversation turns
    foreach my $turn (@new_turns) {
        print $turn->{content} . "\n" if $turn->{role} eq 'assistant';
        push @jstr, $turn;
    }

    # save updated messages to status file
    open(my $sfh_final, '>', $STATUS_FILE)
         or die "Failed to write to $STATUS_FILE: $!\n";
    print {$sfh_final} $json->encode($_)."\n" for @jstr;
    close $sfh_final
         or die "Failed to close $STATUS_FILE: $!\n";

    return;
}

sub _tool_bash {
    my ($args) = @_;
    # dump args to a temp file and execute with bash, capture output
    load_cpan("File::Temp");
    my ($fh, $fn) = File::Temp::tempfile();
    print {$fh} $args;
    if(!close($fh)){
        my $err = $!;
        unlink $fn;
        return "[ERR] Failed to write to temp file for bash command: $err";
    }
    if(open(my $fh, "bash < $fn 2>&1|")){
        local $/;
        my $result = <$fh>;
        close($fh);
        my $err = $?;
        unlink $fn;
        return "[ERR] problem running tool 'bash': $err, output: $result" if $err;
        return $result;
    }
    return "[ERR] Failed to execute command: $args: $!";
}

sub _tool_read {
    my ($args) = @_;
    my $file = trim($args);
    if (open(my $fh, '<', $file)) {
        local $/;
        my $content = <$fh>;
        close($fh);
        return $content // "";
    }
    return "[ERR] File not found: $file: $!";
}

sub _tool_write {
    my ($args) = @_;
    if (shift_args($args, \my $path)) {
        open(my $fh, '>', $path)
            or die "Cannot write to $path: $!";
        print {$fh} shift_args($args);
        if(!close($fh)){
            return "[ERR] problem running tool 'write' for $path: $!";
        }
        return "Written to $path";
    }
    return "[ERR] Usage: /write <path> [content]";
}

sub _tool_grep {
    my ($args) = @_;
    my @parts = split(/\s+/, trim($args), 2);
    if (@parts >= 1) {
        my $path_arg = @parts > 1 ? $parts[1] : '.';
        open(my $fh, "grep", "-r", $parts[0], $path_arg, "-|")
            or return "[ERR] Cannot run grep: $!";
        local $/;
        my $result = <$fh>;
        close($fh);
        return "[ERR] problem running tool 'bash': $?" if $?;
        return $result // "";
    }
    return "[ERR] Usage: /grep <pattern> [path]";
}

sub execute_tool {
    my ($tool, $args) = @_;
    return "[ERR] Unknown tool '$tool'" unless exists $TOOLS->{$tool};
    my $tn = "_tool_$tool";
    my $ret;
    eval {
        # TODO: use Safe Eval AND fork() ?
        no strict 'subs';
        return &{$tn}($args);
    };
    if($@){
        chomp(my $err = $@);
        return "[ERR] problem running tool '$tool': $err";
    }
    return $ret;
}

sub trim {
    my ($s) = @_;
    $s =~ s/^\s+//;
    $s =~ s/\s+$//;
    return $s;
}

sub shift_args {
    my ($args, $ref_path) = @_;
    $args =~ s/^\s+//;
    if ($args =~ /^(\S+)\s*(.*)/) {
        $$ref_path = $1;
        $args = $2;
        return 1;
    }
    return 0;
}

sub list_models {
    my $model_path = $provider_name eq 'anthropic' ? 'models' : 'v1/chat/models';
    my $response = http("get", $model_path);
    if (!$response) {
        log_error("Failed to fetch models");
        return;
    }
    my $resp = JSON::XS::decode_json($response);

    # Handle different response formats
    my @models;
    if (ref($resp) eq 'HASH' and exists $resp->{data}) {
        @models = @{$resp->{data}};
    } elsif (ref($resp) eq 'ARRAY') {
        @models = @$resp;
    } else {
        log_error("Failed to parse models response");
        return;
    }

    foreach my $model (@models) {
        my $id = ref($model) eq 'HASH' ? $model->{id} : $model;
        print "$id\n";
    }
    return;
}

sub setup_commands {
    $cmds //= {
    '/exit'  => \&exitshell,
    '/quit'  => \&exitshell,
    '/clear' => sub {
        open(my $fh, '>', $STATUS_FILE)
            or die "Failed to write to $STATUS_FILE: $!\n";
        print {$fh} $json->encode({ role => 'system', content => '' })."\n";
        close $fh
            or die "Failed to close $STATUS_FILE: $!\n";
        return 0;
    },
    '/history' => sub {
        print do {open(my $_hfh, '<', $HISTORY_FILE) or die "Failed to read $HISTORY_FILE: $!\n"; local $/; <$_hfh>};
        return 0;
    },
    '/debug' => sub {
        $DEBUG = 1;
        return 0;
    },
    '/nodebug' => sub {
        $DEBUG = 0;
        return 0;
    },
    '/tools' => sub {
        print "Available tools:\n";
        foreach my $name (sort keys %$TOOLS) {
            my $info = $TOOLS->{$name};
            print "  /$name: " . $info->{description} . "\n";
            if (my $usage = $info->{usage}) {
                print "    Usage: $usage\n";
            }
        }
        return 0;
    },
    '/system' => sub {
        my ($line) = @_;
        $line =~ s|^/system||;
        open(my $sfh, '>>', $STATUS_FILE)
            or die "Failed to write to $STATUS_FILE: $!\n";
        print {$sfh} $json->encode({ role => 'system', content => $line })."\n";
        close $sfh
            or die "Failed to close $STATUS_FILE: $!\n";
        return 0;
    },
    '/files' => sub {
        my ($line) = @_;
        my $dir_rx = $line;
        $dir_rx =~ s|^/files||;
        $dir_rx =~ s| +$||;
        $dir_rx =~ s|^\s+||;
        $dir_rx = qr/$dir_rx/;
        my $dir = Cwd::cwd();
        if(opendir(my $dh, $dir)){
            my $ignore_list = do {
                local $/;
                open(my $_ifh, '<', '.aiignore') or return '';
                <$_ifh>;
            };
            while (my $file = readdir($dh)) {
                next if $file =~ m/^\./;
                next unless -f $file;
                next if $file !~ m/$dir_rx/;
                next if grep {$file eq $_} map {glob($_)} split m/\n/, $ignore_list;
                my $data = do {
                    my $_ffh;
                    local $/;
                    open($_ffh, '<', $file) and <$_ffh>;
                };
                next unless length($data//"");
                $data = '```'."\n".$data."\n".'```'."\n";
                open(my $sfh, '>>', $STATUS_FILE)
                    or next;
                print {$sfh} $json->encode({role => 'user', content => $data})."\n";
                close $sfh;
                print "${colors::green_color}✓${colors::reset_color} added $file to chat\n";
            }
            closedir $dh;
        }
        return 0;
    },
    '/chdir' => sub {
        my ($line) = @_;
        $line =~ s|^/chdir||;
        $line =~ s| +$||;
        $line =~ s|^\s+||;
        if(chdir($line)){
            return 0;
        } else {
            print "Failed to change directory to $line: $!\n";
            return 0;
        }
    },
    '/ls' => sub {
        my $dir = Cwd::cwd();
        if(opendir(my $dh, $dir)){
            while (my $file = readdir($dh)) {
                next if $file =~ m/^\./;
                print "$file\n";
            }
            closedir $dh;
        }
        return 0;
    },
    '/pwd' => sub {
        print Cwd::cwd()."\n";
        return 0;
    },
    '/session' => {
        'list'   => sub { 0 },
        'create' => sub { 0 },
        'delete' => {},
        'rename' => {},
        'switch' => {},
    },
    '/model'   => {},
    };

    # add models
    my $response = eval { http("get", $ORIG_ENV{AI_LOCAL_SERVER}?"v1/models":"v1/chat/models") };
    my $resp;
    if ($response) {
        $resp = eval { JSON::XS::decode_json($response) };
    }
    my @models;
    if (defined $resp and ref($resp) eq 'HASH' and exists $resp->{data}) {
        @models = @{$resp->{data}};
    } elsif (defined $resp and ref($resp) eq 'ARRAY') {
        push @models, $_ for @$resp;
    }
    $cmds->{'/model'} = {map {$_->{id}, sub {switch_model($_->{id})}} @models};

    # add prompts
    my @prompts = glob("$FindBin::Bin/ai/*");
    $cmds->{'/prompt'} = {map {($_ =~ s/.*\///r, sub {switch_prompt($_)})} @prompts};

    # add available sessions
    refresh_session_completions();
};

sub refresh_session_completions {
    my $available_sessions = get_sessions();
    my $session_cmds = {
        'list'   => sub { 0 },
        'create' => sub { 0 },
        'delete' => {map {($_, sub { 0 })} @$available_sessions},
        'rename' => {map {($_, sub { 0 })} @$available_sessions},
        'switch' => {map {($_, sub {switch_session($_)})} @$available_sessions},
        map {($_, sub {switch_session($_)})} @$available_sessions,
    };
    $cmds->{'/session'} = $session_cmds;
}

sub init_session {
    my ($session) = @_;
    my $session_dir = "$SESSIONS_DIR/$session";
    -d $session_dir or mkdir $session_dir or die "Failed to create $session_dir: $!\n";

    my $p_file = "$session_dir/prompt";
    my $s_file = "$session_dir/chat";

    if((!-s $p_file or ($ORIG_ENV{AI_CLEAR}//0)) and open(my $fh, '<', $AI_PROMPT_TEMPLATE_FILE)){
        local $/;
        my $prompt = <$fh>;
        close($fh);
        open(my $pfh, '>', $p_file)
            or die "Failed to write to $p_file: $!\n";
        print {$pfh} $prompt;
        close $pfh
            or die "Failed to close $p_file: $!\n";
    }
    if(!-s $s_file or ($ORIG_ENV{AI_CLEAR}//0)){
        my $prompt;
        if(open(my $fh, '<', $p_file)){
            local $/;
            $prompt = <$fh>;
            close($fh);
        }
        $prompt .= _tool_list_for_prompt();
        open(my $fh, '>', $s_file)
            or die "Failed to write to $s_file: $!\n";
        print {$fh} $json->encode({role => 'system', content => ($prompt // "")})."\n";
        close $fh
            or die "Failed to close $s_file: $!\n";
    }
}

sub _tool_list_for_prompt {
    my $list = "\nTOOLS 'syntax': \n///TOOL_{HEX}+{T1}+{T2}\n{{path}}\n{T1}\n{{content}}\n{T2}\nTOOL_{HEX}\n where {{path}}, {{content} is substituted by the LLM";
    $list .= "TOOLS:\n```json\n";
    $list .= $json->encode($TOOLS);
    $list .= "\n";
    log_info("TOOLS SECTION>>$list<<");
    return $list;
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
    chomp $new_session;
    $new_session =~ s/^\s*//g;
    $new_session =~ s/\s*$//g;
    if(-d "$SESSIONS_DIR/$new_session"){
        $ENV{AI_SESSION} = $new_session;
        $AI_SESSION = $new_session;
        $AI_SESSION_DIR = "$SESSIONS_DIR/$AI_SESSION";
        $HISTORY_FILE = "$AI_SESSION_DIR/history";
        $PROMPT_FILE  = "$AI_SESSION_DIR/prompt";
        $STATUS_FILE  = "$AI_SESSION_DIR/chat";
        print "Switched to session: $new_session\n";
    } else {
        print "Session '$new_session' does not exist.\n";
    }
}

sub create_session {
    my ($name) = @_;
    $name =~ s/^\s+//; $name =~ s/\s+$//;
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
    $name =~ s/^\s+//; $name =~ s/\s+$//;
    if (!-d "$SESSIONS_DIR/$name") {
        print "Session '$name' does not exist.\n";
        return;
    }
    if ($name eq $AI_SESSION) {
        print "Cannot delete the current session.\n";
        return;
    }
    load_cpan("File::Path");
    File::Path::remove_tree("$SESSIONS_DIR/$name");
    print "Deleted session '$name'.\n";
    refresh_session_completions();
}

sub rename_session {
    my ($old, $new) = @_;
    $old =~ s/^\s+//; $old =~ s/\s+$//;
    $new =~ s/^\s+//; $new =~ s/\s+$//;
    if (!-d "$SESSIONS_DIR/$old") {
        print "Session '$old' does not exist.\n";
        return;
    }
    if (-d "$SESSIONS_DIR/$new") {
        print "Session '$new' already exists.\n";
        return;
    }
    if (rename("$SESSIONS_DIR/$old", "$SESSIONS_DIR/$new")) {
        if ($old eq $AI_SESSION) {
            $ENV{AI_SESSION} = $new;
            $AI_SESSION = $new;
            $AI_SESSION_DIR = "$SESSIONS_DIR/$AI_SESSION";
            $HISTORY_FILE = "$AI_SESSION_DIR/history";
            $PROMPT_FILE  = "$AI_SESSION_DIR/prompt";
            $STATUS_FILE  = "$AI_SESSION_DIR/chat";
        }
        print "Renamed session '$old' to '$new'.\n";
        refresh_session_completions();
    } else {
        print "Failed to rename session: $!\n";
    }
}

sub switch_model {
    my ($new_model) = @_;
    $new_model ||= $ORIG_ENV{AI_MODEL};
    $new_model =~ s/^['"]//;
    $new_model =~ s/['"]$//;
    $new_model =~ s/\s+$//;
    $new_model =~ s/^\s+//;
    my $model_file = "$AI_SESSION_DIR/model";
    my $tmp_model_file = "$model_file.tmp";
    if(open(my $fh, '>', $tmp_model_file)){
        print {$fh} $new_model;
        close($fh) and do {
            if(rename($tmp_model_file, $model_file)){
                print "Switched model to '$new_model'.\n";
                $SESSION_MODEL = $new_model;
            } else {
                print "Failed to switch model: $!\n";
            }
            print "switch: $new_model\n";
        };
    } else {
        print "Failed to write to $tmp_model_file: $!\n";
    }
}

sub switch_prompt {
    my ($new_prompt) = @_;
    my $prompt_file = "$AI_SESSION_DIR/prompt";
    my $tmp_prompt_file = "$prompt_file.tmp";
    my $template = "";
    if(open(my $ofh, "$FindBin::Bin/ai/$new_prompt")){
        local $/;
        $template = <$ofh>;
        close($ofh);
    } else {
        print "Failed to read prompt template: $!\n";
        return;
    }
    if(open(my $fh, '>', $tmp_prompt_file)){
        print {$fh} $template;
        close($fh) and do {
            if(rename($tmp_prompt_file, $prompt_file)){
                print "Switched system prompt.\n";
            } else {
                print "Failed to switch prompt: $!\n";
            }
        };
    } else {
        print "Failed to write to $tmp_prompt_file: $!\n";
    }
}

sub chat_word_completions_cli {
    my ($text, $line, $start, $end) = @_;
    $line =~ s/ +$//g;
    my $cfg = $cmds;
    my @wrd = split m/\s+/, $line, -1;
    log_info("W: >".join("rcs, ", @wrd)."<");
    foreach my $w (@wrd) {
        my @rcs = ();
        return '' if defined $cfg and ref($cfg) ne 'HASH';
        foreach my $k (sort %$cfg) {
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
    local $ENV{TERM}    = $ORIG_ENV{TERM} // 'vt220';
    eval {
        load_cpan("Term::ReadLine");
        load_cpan("Term::ReadLine::Gnu");
    };
    if($@){
        print STDERR "Please install Term::ReadLine and Term::ReadLine::Gnu\n\nE.g.:\n  sudo apt install libterm-readline-gnu-perl\n";
        exit 1;
    }
    my $term = Term::ReadLine->new("aicli");
    $term->read_init_file("$BASE_DIR/inputrc");
    $term->ReadLine('Term::ReadLine::Gnu') eq 'Term::ReadLine::Gnu'
        or die "Term::ReadLine::Gnu needs to be loaded\n";
    $term->enableUTF8();
    $term->using_history();
    $term->ReadHistory($HISTORY_FILE);
    $term->clear_signals();
    my $attribs = $term->Attribs();
    $attribs->{attempted_completion_function} = \&chat_word_completions_cli;
    $attribs->{ignore_completion_duplicates}  = 1;
    return ($term, $attribs);
}

sub get_chat_prompt {
    # https://jafrog.com/2013/11/23/colors-in-terminal.html
    # https://ss64.com/bash/syntax-colors.html
    my $prompt_term1  =
            $ORIG_ENV{AI_PS1}
        //   $colors::reset_color
            .$colors::blue_color3
            .'❲$AI_SESSION'.($SESSION_MODEL?'\[$SESSION_MODEL\]':'').'❳ ► '
            .$colors::reset_color;
    my $prompt_term2  =
            $ORIG_ENV{AI_PS2}
        //   $colors::reset_color
            .$colors::blue_color3
            .'│ '
            .$colors::reset_color;
    my $ps1 = eval 'return "'.$prompt_term1.'"' || '► ';
    my $ps2 = eval 'return "'.$prompt_term2.'"' || '│ ';
    return ($ps1, $ps2);
}

sub input_terminal {
    my ($term, $attribs) = setup_readline();
    return sub {
        my $buf = '';
        my $p1or2 = 0;
      READ_AGAIN:
        my ($t_ps1, $t_ps2) = get_chat_prompt();
        my $line = $term->readline($p1or2 == 0?$t_ps1:$t_ps2);
        return unless defined $line;
        if($line !~ m/^$/ms){
            if(!length($buf)){
                my $r_val = handle_command($line);
                if(defined $r_val){
                    if($r_val == 1){
                        $term->WriteHistory($HISTORY_FILE);
                        return;
                    } else {
                        goto READ_AGAIN;
                    }
                }
            }
            $buf .= "$line\n";
            $p1or2 = 1;
            goto READ_AGAIN;
        } else {
            if(length($buf)){
                log_info("BUF: >>$buf<<");
                $term->addhistory($buf);
                $term->WriteHistory($HISTORY_FILE);
                chomp $buf;
                return $buf;
            } else {
                goto READ_AGAIN;
            }
        }
        return;
    };
}

sub input_stdin {
    return sub {
        my $line = <STDIN>;
        return unless defined $line;
        if ($line =~ m|^/|) {
            handle_command($line);
            return "";
        }
        return $line;
    };
}

sub chat_loop {
    my $input_cli_sub = -t STDIN ? input_terminal() : input_stdin();
    while(1){
        log_info("Waiting for user input...");
        my $chat_request = &{$input_cli_sub}();
        unless(defined $chat_request){
            print "\n";
            last;
        }
        next if $chat_request =~ m/^\s*$/;
        chat_completion($chat_request);
    }
    return;
}

sub handle_command {
    my ($line) = @_;
    log_info("Command: $line");
    if ($line =~ m|^/system|) {
        $line =~ s|^/system||;
        open(my $sfh, '>>', $STATUS_FILE)
            or die "Failed to write to $STATUS_FILE: $!\n";
        print {$sfh} $json->encode({ role => 'system', content => $line })."\n";
        close $sfh
            or die "Failed to close $STATUS_FILE: $!\n";
        return 0;
    }
    if ($line =~ m|^/exit| or $line =~ m|^/quit|) {
        return 1;
    }
    if ($line =~ m|^/clear|) {
        my $prompt = -f $PROMPT_FILE ? do {
            open(my $fh, '<', $PROMPT_FILE)
                or die "Failed to read $PROMPT_FILE: $!\n";
            local $/; <$fh>
        }:'';
        open(my $fh, '>', $STATUS_FILE)
            or die "Failed to write to $STATUS_FILE: $!\n";
        print {$fh} $json->encode({ role => 'system', content => ($prompt // "") })."\n";
        close $fh
            or die "Failed to close $STATUS_FILE: $!\n";
        return 0;
    }
    if ($line =~ m|^/history|) {
        print do {open(my $_hfh, '<', $HISTORY_FILE) or die "Failed to read $HISTORY_FILE: $!\n"; local $/; <$_hfh>};
        return 0;
    }
    if ($line =~ m|^/debug|) {
        $DEBUG = 1;
        return 0;
    }
    if ($line =~ m|^/nodebug|) {
        $DEBUG = 0;
        return 0;
    }
    if ($line =~ m|^/tools$|) {
        print "Available tools:\n";
        foreach my $name (sort keys %$TOOLS) {
            my $info = $TOOLS->{$name};
            print "  /$name: " . $info->{description} . "\n";
            if (my $usage = $info->{usage}) {
                print "    Usage: $usage\n";
            }
        }
        return 0;
    }
    if ($line =~ m|^/help|) {
        print join(", ", sort keys %$cmds)."\n";
        return 0;
    }
    if ($line =~ m|^/chdir|) {
        $line =~ s|^/chdir||;
        $line =~ s| +$||;
        $line =~ s|^\s+||;
        if(chdir($line)){
            return 0;
        } else {
            print "Failed to change directory to $line: $!\n";
            return 0;
        }
    }
    if ($line =~ m|^/ls|) {
        my $dir = Cwd::cwd();
        if(opendir(my $dh, $dir)){
            while (my $file = readdir($dh)) {
                next if $file =~ m/^\./;
                print "$file\n";
            }
            closedir $dh;
        }
        return 0;
    }
    if ($line =~ m|^/pwd|) {
        print Cwd::cwd()."\n";
        return 0;
    }
    if ($line =~ m|^/session|) {
        if ($line =~ m|^/session\s+create\s+(.*)$|) {
            create_session($1);
        } elsif ($line =~ m|^/session\s+delete\s+(.*)$|) {
            delete_session($1);
        } elsif ($line =~ m|^/session\s+rename\s+(\S+)\s+(\S+)$|) {
            rename_session($1, $2);
        } elsif ($line =~ m|^/session\s+list\s*$|) {
            list_sessions();
        } elsif ($line =~ m|^/session\s+switch\s+(.*)$|) {
            switch_session($1);
        } elsif ($line =~ m|^/session\s+(.*)$| and length($1//"")) {
            switch_session($1);
        } elsif ($line =~ m|^/session\s*$|) {
            list_sessions();
        }
        return 0;
    }
    if ($line =~ m|^/model|) {
        my $model_file = "$AI_SESSION_DIR/model";
        my $current_model;
        if(open(my $fh, '<', $model_file)){
            $current_model = <$fh>;
            $current_model ||= $ORIG_ENV{AI_MODEL};
            $current_model =~ s/^['"]//;
            $current_model =~ s/['"]$//;
            $current_model =~ s/\s+$//;
            $current_model =~ s/^\s+//;
            chomp $current_model;
            close $fh;
        }
        if($line =~ m|^/model\s+(.*)$| and length($1//"")){
            switch_model($1);
        } elsif ($line =~ m|^/model\s*$|){
            # Show available models from the API
            my $response = http("get", $ORIG_ENV{AI_LOCAL_SERVER}?"v1/models":"v1/chat/models");
            log_info("Response: $response");
            my $resp = JSON::XS::decode_json($response);
            my @models;
            if (defined $resp and ref($resp) eq 'HASH' and exists $resp->{data}) {
                @models = @{$resp->{data}};
            } elsif (defined $resp and ref($resp) eq 'ARRAY') {
                foreach my $model (@$resp) {
                    push @models, $model;
                }
            } else {
                log_error("Failed to parse models response");
            }
            foreach my $model (@models) {
                if ($model->{id} eq $current_model) {
                    print "${colors::green_color}* $model->{id}${colors::reset_color}\n";
                } else {
                    print "  $model->{id}\n";
                }
            }
        }
        return 0;
    }
    if ($line =~ m|^/prompt|) {
        if($line =~ m|^/prompt\s+(.*)$| and length($1//"")){
            switch_prompt($1);
        } elsif($line =~ m|^/prompt\s*$|){
            # show available prompts from the prompts directory
            # if the prompt file exists in the session, show that as well
            my $prompt_dir = $FindBin::Bin.'/ai';
            my @prompts = glob("$prompt_dir/*");
            my $current_prompt = '';
            if(open(my $fh, '<', $PROMPT_FILE)){
                local $/;
                $current_prompt = <$fh>;
            }
            foreach my $prompt (@prompts) {
                next if $prompt =~ m/^\.\.?$/;
                my $prompt_name = $prompt;
                $prompt_name =~ s/.*\///;
                my $prompt_data;
                if(open(my $fh, '<', $prompt)){
                    local $/;
                    $prompt_data = <$fh>;
                } else {
                    next;
                }
                if ($current_prompt eq $prompt_data) {
                    print "${colors::green_color}* $prompt_name${colors::reset_color}\n";
                } else {
                    print "  $prompt_name\n";
                }
            }
        }
        return 0;
    }
    if ($line =~ m|^/files|) {
        # slurp the directory and add the contents of the files to the chat
        my $dir_rx = $line;
        $dir_rx =~ s|^/files||;
        $dir_rx =~ s| +$||;
        $dir_rx =~ s|^\s+||;
        $dir_rx = qr/$dir_rx/;
        my $dir = Cwd::cwd();
        if(opendir(my $dh, $dir)){
            my $ignore_list = do {
                local $/;
                open(my $_ifh, '<', '.aiignore') or return '';
                <$_ifh>;
            };
            while (my $file = readdir($dh)) {
                next if $file =~ m/^\./;
                next unless -f $file;
                next if $file !~ m/$dir_rx/;
                next if grep {$file eq $_} map {glob($_)} split m/\n/, $ignore_list;
                my $data = do {
                    my $_ffh;
                    local $/;
                    open($_ffh, '<', $file) and <$_ffh>;
                };
                next unless length($data//"");
                $data = '```'."\n".$data."\n".'```'."\n";
                open(my $sfh, '>>', $STATUS_FILE)
                    or next;
                print {$sfh} $json->encode({role => 'user', content => $data})."\n";
                close $sfh;
                print "${colors::green_color}✓${colors::reset_color} added $file to chat\n";
            }
            closedir $dh;
        }
        return 0;
    }
    if ($line =~ m|^/|) {
        print "Unknown command: $line\n";
        return 0;
    }
    return;
}

sub http {
    my ($m, $path, $data) = @_;
    my $full_url = "$ai_endpoint_url/$path";
    eval {load_cpan("WWW::Curl::Easy")};
    if($@){
        log_error("Please install WWW::Curl::Easy\n\nE.g.:\n  sudo apt install libwww-curl-perl");
        exit 1;
    }
    $data //= "";
    log_info("URL: $full_url");
    log_info("DATA: $data");
    $curl_handle //= do {
        my $ch = WWW::Curl::Easy->new();
        $ch->setopt(WWW::Curl::Easy::CURLOPT_IPRESOLVE(), WWW::Curl::Easy::CURL_IPRESOLVE_V6());
        $ch->setopt(WWW::Curl::Easy::CURLOPT_WRITEFUNCTION(), sub {
            my ($chunk, $u_ref) = @_;
            $$u_ref .= $chunk;
            return length($chunk);
        });
        $ch->setopt(WWW::Curl::Easy::CURLOPT_VERBOSE(), $DEBUG?1:0);
        $ch->setopt(WWW::Curl::Easy::CURLOPT_HTTPHEADER(), [
            "Accept: application/json",
            "Content-Type: application/json",
            "User-Agent: AI Chat/0.1",
            "Connection: Keep-Alive",
            "Keep-Alive: max=100",
            ($api_key ?(
                "Authorization: Bearer $api_key",
            ):()),
        ]);
        if(my $proxy = $ORIG_ENV{AI_PROXY} // $ORIG_ENV{HTTPS_PROXY} // $ORIG_ENV{HTTP_PROXY}){
            $ch->setopt(WWW::Curl::Easy::CURLOPT_PROXY(), $proxy);
        }
        $ch;
    };
    $curl_handle->setopt(WWW::Curl::Easy::CURLOPT_URL(), $full_url);
    my $resp = "";
    $curl_handle->setopt(WWW::Curl::Easy::CURLOPT_WRITEDATA(), \$resp);
    if(lc($m) eq "post"){
        $curl_handle->setopt(WWW::Curl::Easy::CURLOPT_POST(), 1);
        if(length($data)){
            $curl_handle->setopt(WWW::Curl::Easy::CURLOPT_POSTFIELDS(), $data);
            $curl_handle->setopt(WWW::Curl::Easy::CURLOPT_POSTFIELDSIZE_LARGE(), length($data));
        }
    }
    if(lc($m) eq "get"){
        $curl_handle->setopt(WWW::Curl::Easy::CURLOPT_HTTPGET(), 1);
    }
    $curl_handle->perform();
    my $r_code = $curl_handle->getinfo(WWW::Curl::Easy::CURLINFO_HTTP_CODE());
    if($r_code != 200){
        log_info("ERROR: $r_code");
        return;
    }
    log_info("OK: $r_code");
    log_info("RESPONSE:\n$resp");
    return $resp;
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

__END__

=head1 NAME

ai.pl - AI Chat CLI

=head1 SYNOPSIS

ai.pl [options]

 Options:
   -help            brief help message
   -debug           enable debug mode

=head1 OPTIONS

=over 8

=item B<-help>

Print a brief help message and exits.

=item B<-debug>

Enable debug mode.

=back

=head1 DESCRIPTION

B<ai.pl> is a command-line interface for interacting with an AI chat model.

=head1 COMMANDS

=over 8

=item B</exit> or B</quit>

Exit the chat.

=item B</clear>

Clear the chat status file.

=item B</history>

Show the chat history.

=item B</help>

Show the list of available commands.

=item B</debug>

Enable debug mode.

=item B</nodebug>

Disable debug mode.

=item B</system>

Send a system message to the chat.

=item B</chdir>

Change the current working directory.

=item B</ls>

List files in the current directory.

=item B</pwd>

Print the current working directory.

=item B</session>

Manage chat sessions.
  /session                 - List all sessions
  /session list            - List all sessions
  /session create <name>   - Create a new session and switch to it
  /session delete <name>   - Delete a session
  /session rename <old> <new> - Rename a session
  /session switch <name>   - Switch to a session
  /session <name>          - Switch to a session (shortcut)

=item B</model>

Manage AI models for the current model
  /model              - Show current model
  /model <model_name> - Set model for this model

=back

=head1 SUPPORTED PROVIDERS

The following providers are supported:

=over 8

=item B<Cerebras>

API key prefix: C<csk->

=item B<OpenRouter>

API key prefix: C<sk-or->

=item B<OpenAI>

API key prefix: C<sk-> (standard OpenAI keys)

=item B<Groq>

API key prefix: C<gsk_->

=item B Anthropic>

API key prefix: C<sk-ant->

=item B<AWS Bedrock>

Use AWS credentials for authentication.

=item B<Lemonade (ROCm)>

Local LLM server for AMD ROCm GPUs. Default URL: C<http://localhost:8000/v1>

=back

Providers can be auto-detected from API key prefixes, or explicitly set via the B<AI_PROVIDER>
environment variable.

=head1 ENVIRONMENT VARIABLES

=over 8

=item B<AI_DIR>

Base directory for AI configuration and data files.

=item B<AI_CONFIG>

Path to the AI configuration file.

=item B<DEBUG>

Enable or disable debug mode.

=item B<AI_SESSION>

Prompt string for the AI chat.

=item B<AI_API_KEY>

API key for accessing the AI API.

=item B<AI_MODEL>

Model name for the AI chat.

=item B<AI_TOKENS>

Maximum number of tokens for the AI chat completion.

=item B<AI_TEMPERATURE>

Temperature setting for the AI chat completion.

=item B<AI_CLEAR>

Clear the chat status file if set.

=item B<AI_PROVIDER>

Specify the AI provider to use. Options: cerebras, openrouter, openai, groq, anthropic, bedrock, lemonade.
If not specified, will be auto-detected from API key prefix.

=item B<AI_LOCAL_SERVER>

URL for a local llama.cpp server (overrides provider settings).

=item B<AI_PROXY>

Proxy URL for HTTP/HTTPS requests (e.g., http://proxy:8080).

=item B<HTTPS_PROXY>

Fallback proxy URL if AI_PROXY not set.

=item B<HTTP_PROXY>

Fallback proxy URL if AI_PROXY and HTTPS_PROXY not set.

=back

=cut
