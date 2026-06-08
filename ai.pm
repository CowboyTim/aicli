package ai;

use strict; use warnings;

use utils;

use Cwd qw();
use Encode qw(_utf8_off);
use Errno;
use JSON::XS;

BEGIN {
    $::JSON //= JSON::XS->new->utf8->allow_blessed->allow_unknown->allow_nonref->convert_blessed;
}

# Variables/Handles
our ($api_key, $AI_ENDPOINT_URL, $SESSION_MODEL, $provider_name, $v1_prefix);
our ($AI_SESSION_DIR, $HISTORY_FILE, $PROMPT_FILE, $STATUS_FILE, $BASE_DIR, $AI_PROMPT_TEMPLATE, $AI_PROMPT_TEMPLATE_FILE, $AI_SESSION, $SESSIONS_DIR);
our $cmds;

sub chat_setup {
    my ($base_dir) = @_;
    if($::ORIG_ENV{CDIR}){
        chdir($::ORIG_ENV{CDIR})
            or die "Error chdir to CDIR=$::ORIG_ENV{CDIR}: $!\n";
    }

    $BASE_DIR = $base_dir;
    my $cfg_file = $::ORIG_ENV{AI_CONFIG}
        // "$BASE_DIR/config";
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
    if (!$AI_SESSION) {
        # Generate a UUID for default session
        eval {utils::load_cpan("Data::UUID")};
        if ($@) {
            log::error("Please install Data::UUID module to generate UUIDs");
            exit 1;
        }
        my $ug = Data::UUID->new();
        $AI_SESSION = "session-" . $ug->create_str();
    }
    $AI_SESSION_DIR = "$SESSIONS_DIR/$AI_SESSION";
    -d $AI_SESSION_DIR
        or mkdir $AI_SESSION_DIR
        or die "Failed to create $AI_SESSION_DIR: $!\n";

    $BASE_DIR       = $base_dir;

    # Get model for this session
    $HISTORY_FILE = "$AI_SESSION_DIR/history";
    $PROMPT_FILE  = "$AI_SESSION_DIR/prompt";
    $STATUS_FILE  = "$AI_SESSION_DIR/chat";
    my $model_file = "$AI_SESSION_DIR/model";
    if(open(my $mfh, '<', $model_file)){
        $SESSION_MODEL = <$mfh>;
        $SESSION_MODEL ||= $::ORIG_ENV{AI_MODEL};
        $SESSION_MODEL =~ s/^['"]//;
        $SESSION_MODEL =~ s/['"]$//;
        $SESSION_MODEL =~ s/\s+$//;
        $SESSION_MODEL =~ s/^\s+//;
        chomp $SESSION_MODEL;
        close $mfh;
    }
    $SESSION_MODEL ||= $::ORIG_ENV{AI_MODEL};

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

    $provider_name = lc($::ORIG_ENV{AI_PROVIDER} // '');

    # Check for local llama.cpp server
    if ($::ORIG_ENV{AI_LOCAL_SERVER}) {
        $AI_ENDPOINT_URL = $::ORIG_ENV{AI_LOCAL_SERVER};
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
            $AI_ENDPOINT_URL = $PROVIDERS{$provider_name}{url};
        } elsif ($detected_provider) {
            $AI_ENDPOINT_URL = $PROVIDERS{$detected_provider}{url};
        } else {
            log::error("Unable to detect provider from API key. Set AI_PROVIDER environment variable");
            log::error("Supported providers: ".join(', ', keys %PROVIDERS));
            exit 1;
        }
        $api_key = $::ORIG_ENV{AI_API_KEY};
        if (!$api_key) {
            log::error("Please set AI_API_KEY environment variable or set $BASE_DIR/config");
            exit 1;
        }
        if ($provider_name) {
            $v1_prefix = $provider_name eq 'anthropic' ? '' : 'v1/';
        } else {
            $v1_prefix = 'v1/';
        }
    }

    # Normalize URL - ensure it doesn't end with / for some endpoints
    $AI_ENDPOINT_URL =~ s|/+$||;
    init_session($AI_SESSION);
    return;
}

our $t_rx;
sub handle_llm_response {
    my ($resp, $printer_sub) = @_;
    return (0, 0, []) unless defined $resp and ref($resp) eq 'SCALAR' and length($$resp // "");
    log::info("handling>>".(${$resp //= \""})."<<");
    $printer_sub //= sub {
        my ($r) = @_;
        print $r;
    };

    my $pos = 0;
    my $newturns = 0;

    my @rt;
    my $msg_no_think = $$resp =~ s/^<think>.*?^<\/think>$//msgr;
    _utf8_off($msg_no_think);
    log::info("MSG THINK STRIPPED>>$msg_no_think<<");
    $t_rx //= tools::rx();
    log::info("TOOL RX: $t_rx");
    while($msg_no_think =~ m/$t_rx/msgo){
        my $tool_entry = $1;
        log::info("TOOL MATCH: $tool_entry");
        my @t_args;
        @t_args = map {substr($msg_no_think, $-[$_], $+[$_] - $-[$_])} grep {defined $-[$_] and $+[$_]} 2 .. @--1 if @- >= 3;
        $tool_entry =~ m{^///((.*?)_[a-fA-F0-9]+)}gms;
        my $tool   = $1;
        my $tool_k = lc $2;
        log::info("TOOL:$tool, K:$tool_k, A:".join(' ', @t_args));
        next unless exists $tools::TOOLS->{$tool_k};
        substr($msg_no_think, 0, pos($msg_no_think)) = '';

        &{$printer_sub}("${colors::yellow_color1}\[TOOL $tool\(...))\]${colors::reset_color}\n");
        my ($result, $had_error) = execute_tool($tool_k, $tool, \@t_args);
        my $tool_response = "";
        if(!$had_error){
            $tool_response = "[$tool RESULT_d170b4e6bb11cfd550aa\n$result\nRESULT_d170b4e6bb11cfd550aa]";
        } else {
            $result //= "";
            $tool_response = "[$tool ERROR_9a7893514ebc885c2543\n$had_error\nERROR_9a7893514ebc885c2543]";
        }
        &{$printer_sub}("${colors::green_color}$tool_response${colors::reset_color}\n");
        push @rt, {role => 'user', content => $tool_response};
        $pos = pos($msg_no_think);  # Update position for next iteration
        $newturns = 1;
    }
    log::info("MSG>>$msg_no_think<< POS: ".(pos($msg_no_think)//0));

    return $newturns, $pos, \@rt;
}

our $TOOLS = [];
sub chat_completion {
    my ($input) = @_;
    log::info("User input: $input");

    # Get current messages, add user message
    open(my $fh_read, '<', $STATUS_FILE)
        or die "Failed to read $STATUS_FILE: $!\n";
    my @jstr = do {map {chomp; JSON::XS::decode_json($_)} <$fh_read>};
    close $fh_read;
    push @jstr, {
        role    => 'user',
        content => $input,
#        tools   => $TOOLS //= [
#            map {{type => "function", function => {
#                name        => $_,
#                description => $tools::TOOLS->{$_}{description},
#                properties  => $tools::TOOLS->{$_}{properties} // {},
#                required    => $tools::TOOLS->{$_}{required}   // [],
#            }}} sort keys %{$tools::TOOLS},
#        ]
    };

    my $req = {
        model       => $SESSION_MODEL || $::ORIG_ENV{AI_MODEL} // 'llama-4-scout-17b-16e-instruct',
        max_tokens  => $::ORIG_ENV{AI_TOKENS}      // 1_000_000,
        temperature => $::ORIG_ENV{AI_TEMPERATURE} // 0,
        top_p       => $::ORIG_ENV{AI_TOP_P}       // 1,
        stream      => $Types::Serialiser::true,
        messages    => \@jstr,
    };

    # Provider-specific options
    $req->{provider} = {only => ["Cerebras"]} if ($provider_name//'') eq 'openrouter';
    log::info($::JSON->encode($req));
    log::info("Requesting completion from AI API $AI_ENDPOINT_URL with ".($api_key//'<no api key>'));

    CHAT_LOOP:
    # Variable to hold the assembled assistant message
    my $newturns = 0;
    my $resp = '';

    my $r_sub = ($::ORIG_ENV{AI_STREAM}//1)
    ? sub {
        my ($ch, $raw) = @_;
        log::info("GOT STREAM $raw");
        my $sz = length($raw);

        *STDOUT->autoflush();
        *STDERR->autoflush();
        local $| = 1;
        # Parse Server-Sent Events (SSE) stream
        while($raw =~ s/(.*?)\n\n//ms){
            my $event = $1 // "";
            next unless $event =~ s/^data:\s*//;
            if($event eq '[DONE]'){
                print "\n";
                last
            }
            eval {
                my $decoded = JSON::XS->new->utf8->decode($event);
                my $delta = $decoded->{choices}[0]{delta}{content}
                         // $decoded->{choices}[0]{message}{content};
                if(length($delta//"")){
                    log::info("STREAM $delta");
                    _utf8_off($delta);
                    $resp .= $delta;
                    print $delta;
                }
            };
            if($@){
                log::info("Failed to decode SSE event: $event, error: $@");
                last;
            }
        }
        if(length($raw)){
            eval {
                my $decoded = JSON::XS->new->utf8->decode($raw);
                log::error(${colors::red_color}.$decoded->{error}.${colors::reset_color});
            };
            if($@){
                log::error(${colors::red_color}.$raw.${colors::reset_color});
            }
        }
        return $sz;
    }
    : sub {
        my ($ch, $raw) = @_;
        log::info("GOT FULL $raw");
        my $sz = length($raw);
        # Non‑streaming response (original behaviour)
        eval {
            my $decoded = JSON::XS->new->utf8->decode($raw);
            unless (exists $decoded->{choices}[0]{message}{content}) {
                log::error("Failed JSON no message content: ".$::JSON->encode($decoded));
                return;
            }
            $resp = $decoded->{choices}[0]{message}{content};
        };
        if($@){
            log::error("Failed to parse response: $raw");
        }
        return $sz;
    };

    my $raw = utils::http("post", "$AI_ENDPOINT_URL/v1/chat/completions", $::JSON->encode($req), $api_key, $r_sub);
    if(!$raw){
        log::error("No response from API");
        return;
    }

    # save in history
    push @jstr, {role => 'assistant', content => $resp};

    # handle tools
    my ($t, $p, $r) = handle_llm_response(\$resp);
    $newturns ||= $t;
    push @jstr, @{$r//[]};

    # Add any remaining text after last tool call as final assistant message
    $p //= 0;
    if (length($resp) and $p < length($resp)) {
        my $remaining_text = substr($resp, $p);
        if(length($remaining_text)){
            _utf8_off($remaining_text);
            print $remaining_text, "\n";
        }
    }

    # save updated messages to status file
    open(my $sfh_final, '>', $STATUS_FILE)
         or die "Failed to write to $STATUS_FILE: $!\n";
    print {$sfh_final} $::JSON->encode($_)."\n" for @jstr;
    close $sfh_final
         or die "Failed to close $STATUS_FILE: $!\n";

    goto CHAT_LOOP if $newturns;
    return;
}

sub execute_tool {
    my ($k, $tool, $t_args) = @_;
    return "", "[ERROR] Unknown tool '$tool'" unless exists $tools::TOOLS->{$k};
    my $tn = lc("tools::$tool");
    my $ret =
    eval {
        # TODO: use Safe Eval AND fork() ?
        no strict 'refs';
        return &{$tn}($t_args);
    };
    if($@){
        chomp(my $err = $@);
        return "", "[ERROR] problem running tool '$tool': $err";
    }
    return $ret, undef;
}

sub list_models {
    my $model_path = $provider_name eq 'anthropic' ? 'models' : 'v1/chat/models';
    my $response = http("get", $model_path);
    if (!$response) {
        log::error("Failed to fetch models");
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
        log::error("Failed to parse models response");
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
        print {$fh} $::JSON->encode({ role => 'system', content => '' })."\n";
        close $fh
            or die "Failed to close $STATUS_FILE: $!\n";
        return 0;
    },
    '/history' => sub {
        print do {open(my $_hfh, '<', $HISTORY_FILE) or die "Failed to read $HISTORY_FILE: $!\n"; local $/; <$_hfh>};
        return 0;
    },
    '/debug' => sub {
        $::DEBUG = 1;
        return 0;
    },
    '/nodebug' => sub {
        $::DEBUG = 0;
        return 0;
    },
    '/tools' => sub {
        print "Available tools:\n";
        foreach my $name (sort keys %$tools::TOOLS) {
            my $info = $tools::TOOLS->{$name};
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
        print {$sfh} $::JSON->encode({ role => 'system', content => $line })."\n";
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
                print {$sfh} $::JSON->encode({role => 'user', content => $data})."\n";
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
    my $response = eval {utils::http("get", $::ORIG_ENV{AI_LOCAL_SERVER}?"$AI_ENDPOINT_URL/v1/models":"$AI_ENDPOINT_URL/v1/chat/models")};
    my $resp;
    if ($response) {
        $resp = eval {JSON::XS::decode_json($response)};
    }
    my @models;
    if (defined $resp and ref($resp) eq 'HASH' and exists $resp->{data}) {
        @models = @{$resp->{data}};
    } elsif (defined $resp and ref($resp) eq 'ARRAY') {
        push @models, $_ for @$resp;
    }
    $cmds->{'/model'} = {map {$_->{id}, sub {switch_model($_->{id})}} @models};

    # add prompts
    my @all_prompts = glob("$FindBin::Bin/ai/*");
    $cmds->{'/prompt'} = {map {($_ =~ s/.*\///r, sub {switch_prompt($_)})} @all_prompts};

    # add available sessions
    refresh_session_completions();
}

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

    log::info("checking setup: AI_CLEAR=".($ENV{AI_CLEAR}//0).", $p_file, $s_file, $AI_PROMPT_TEMPLATE_FILE");
    if(!-s $p_file or ($::ORIG_ENV{AI_CLEAR}//0)){
        my $prompt = "";
        if(open(my $fh, '<', $AI_PROMPT_TEMPLATE_FILE)){
            log::info("using/updating $AI_PROMPT_TEMPLATE_FILE for prompt");
            local $/;
            $prompt = <$fh>;
            close($fh);
        } else {
            log::info("no prompt file $AI_PROMPT_TEMPLATE_FILE, clearing $p_file");
        }
        open(my $pfh, '>', $p_file)
            or die "Failed to write to $p_file: $!\n";
        print {$pfh} $prompt;
        close $pfh
            or die "Failed to close $p_file: $!\n";
    }
    if(!-s $s_file or ($::ORIG_ENV{AI_CLEAR}//0)){
        my $prompt;
        if(open(my $fh, '<', $p_file)){
            local $/;
            $prompt = <$fh>;
            close($fh);
        }
        if(UNIVERSAL::can("prompt::${AI_PROMPT_TEMPLATE}","prompt")){
            log::info("PROMPT check for 'prompt::${AI_PROMPT_TEMPLATE}'");
            no strict "refs";
            $prompt .= &{"prompt::${AI_PROMPT_TEMPLATE}::prompt"}() // "";
        }
        open(my $fh, '>', $s_file)
            or die "Failed to write to $s_file: $!\n";
        print {$fh} $::JSON->encode({role => 'system', content => ($prompt // "")})."\n";
        close $fh
            or die "Failed to close $s_file: $!\n";
    }
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
    utils::load_cpan("File::Path");
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
    $new_model ||= $::ORIG_ENV{AI_MODEL};
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
    log::info("W: >".join("rcs, ", @wrd)."<");
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
    local $ENV{TERM}    = $::ORIG_ENV{TERM} // 'vt220';
    eval {
        utils::load_cpan("Term::ReadLine");
        utils::load_cpan("Term::ReadLine::Gnu");
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
                log::info("BUF: >>$buf<<");
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
        log::info("Waiting for user input...");
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
    log::info("Command: $line");
    if ($line =~ m|^/system|) {
        $line =~ s|^/system||;
        open(my $sfh, '>>', $STATUS_FILE)
            or die "Failed to write to $STATUS_FILE: $!\n";
        print {$sfh} $::JSON->encode({ role => 'system', content => $line })."\n";
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
        print {$fh} $::JSON->encode({ role => 'system', content => ($prompt // "") })."\n";
        close $fh
            or die "Failed to close $STATUS_FILE: $!\n";
        return 0;
    }
    if ($line =~ m|^/history|) {
        print do {open(my $_hfh, '<', $HISTORY_FILE) or die "Failed to read $HISTORY_FILE: $!\n"; local $/; <$_hfh>};
        return 0;
    }
    if ($line =~ m|^/debug|) {
        $::DEBUG = 1;
        return 0;
    }
    if ($line =~ m|^/nodebug|) {
        $::DEBUG = 0;
        return 0;
    }
    if ($line =~ m|^/tools$|) {
        print "Available tools:\n";
        foreach my $name (sort keys %$tools::TOOLS) {
            my $info = $tools::TOOLS->{$name};
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
            $current_model ||= $::ORIG_ENV{AI_MODEL};
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
            my $response = utils::http("get", $::ORIG_ENV{AI_LOCAL_SERVER}?"$AI_ENDPOINT_URL/v1/models":"$AI_ENDPOINT_URL/v1/chat/models");
            log::info("Response: $response");
            my $resp = JSON::XS::decode_json($response);
            my @models;
            if (defined $resp and ref($resp) eq 'HASH' and exists $resp->{data}) {
                @models = @{$resp->{data}};
            } elsif (defined $resp and ref($resp) eq 'ARRAY') {
                foreach my $model (@$resp) {
                    push @models, $model;
                }
            } else {
                log::error("Failed to parse models response");
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
                print {$sfh} $::JSON->encode({role => 'user', content => $data})."\n";
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

package prompt;

package prompt::default;

BEGIN {
    no warnings 'once';
    *prompt::default::prompt = *{prompt::coder::prompt};
}

package prompt::coder;

sub prompt {
    my $list = "\n\n**TOOLS**\n\n";
    $list .= "\n\nTOOLS SYNTAX, for tool 'TOOL':\n\n";
    $list .= "```\n///TOOL_{HEX}+{T1}+{T2}\n{{path}}\n{T1}\n{{content}}\n{T2}\nTOOL_{HEX}\n```\nWhere {{path}}, {{content}} is substituted by the LLM\n";
    $list .= "TOOL results: [<TOOL_{HEX}> RESULT_d170b4e6bb11cfd550aa\n{{result}}\nRESULT_d170b4e6bb11cfd550aa]\n";
    $list .= "TOOL errors: [<TOOL_{HEX}> ERROR_9a7893514ebc885c2543\n{{error}}\nERROR_9a7893514ebc885c2543]\n";
    $list .= "\n\nLIST OF TOOLS:\n\n";
#    $list .= "```json\n".$::JSON->encode($tools::TOOLS);
    $list .= join("\n\n", map {
        "name: $_\n".
        "tool: ```\n$tools::TOOLS->{$_}{syntax}\n```\n".
        "description: $tools::TOOLS->{$_}{description}\n".
        "properties:\n"._kv_print($tools::TOOLS->{$_}{properties}, 1)
    } sort keys %{$tools::TOOLS});
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
        syntax => "///BASH_7c48+EO_dfd7e6b99d1bf15480fa\n{{code}}\nEO_dfd7e6b99d1bf15480fa\nBASH_7c48",
        properties  => {
            "code" => {type => "string", description => "The bash code to execute"},
        },
        required => ["code"],
        example => <<EOb
///BASH_7c48+EO_dfd7e6b99d1bf15480fa
pwd
ls -la
EO_dfd7e6b99d1bf15480fa
BASH_7c48
EOb
    },
    perl => {
        description => "execute a perl script",
        syntax => "///PERL_d8d2+EO_929b2e8d61111fac138f\n{{code}}\nEO_929b2e8d61111fac138f\nPERL_d8d2",
        properties  => {
            "code" => {type => "string", description => "The perl code to execute"},
        },
        required => ["code"],
    },
    read => {
        description => "read a file contents",
        syntax => "///READ_c5a3+EO_d0f15b09ea7648f828e7\n{{path}}\nEO_d0f15b09ea7648f828e7\nREAD_c5a3",
        properties  => {
            "path" => {type => "string", description => "The path to the file"},
        },
        required => ["path"],
    },
    write => {
        description => "write or overwrite a file",
        syntax => "///WRITE_edf5+EO_d0684c052bf3d9c503a8+EO_ecdeef376b1647fa824a\n{{path}}\nEO_d0684c052bf3d9c503a8\n{{content}}\nEO_ecdeef376b1647fa824a\nWRITE_edf5",
        properties  => {
            "path"    => {type => "string", description => "The path to the file"},
            "content" => {type => "string", description => "The raw text content to write"},
        },
        required => ["path", "content"],
        example => <<EOb
///WRITE_edf5+EO_d0684c052bf3d9c503a8+EO_ecdeef376b1647fa824a
perl_program.pl
EO_d0684c052bf3d9c503a8
#!/usr/bin/perl
print "Hello, World!\\n";
EO_ecdeef376b1647fa824a
WRITE_edf5
EOb
    },
    grep => {
        description => "search file with a pattern using grep unix tool",
        syntax => "///GREP_6629+EO_a575a5c230c77d451640+EO_aaddf906cba61ec85a13\n{{path}}\nEO_a575a5c230c77d451640\n{{regex}}\nEO_aaddf906cba61ec85a13\nGREP_6629",
        properties  => {
            "path"  => {type => "string", description => "The file path or directory to scan"},
            "regex" => {type => "string", description => "The grep pattern"},
        },
        required => ["path", "regex"],
    },
    };

    my @all_t_rx;
    foreach my $t (sort values %{$tools::TOOLS//{}}){
        my $t_rx = $t->{syntax};
        $t_rx =~ s/\{\{.*?\}\}/(.*?)/msg;
        #$t_rx =~ s/\{\{.*?\}\}/((?:(?!\\\/\\\/\\\/).)*?)/msg;
        $t_rx =~ s/\+/\\+/msg;
        $t_rx =~ s/\n/\\n/msg;
        push @all_t_rx, "(?:$t_rx)";
    }
    $TOOLS_RX = '('.join('|', @all_t_rx).')';
}

sub rx {
    $TOOLS_RX;
}

sub bash_7c48 {
    my ($t_args) = @_;
    # dump args to a temp file and execute with bash, capture output
    utils::load_cpan("File::Temp");
    my ($fh, $fn) = File::Temp::tempfile();
    print {$fh} $t_args->[0];
    if(!close($fh)){
        my $err = $!;
        unlink $fn;
        return "[ERROR] failed to write to temp file: $err";
    }
    local $ENV{PATH} = $::ORIG_ENV{PATH};
    local $ENV{HOME} = $::ORIG_ENV{HOME};
    local $ENV{LOGNAME} = $::ORIG_ENV{LOGNAME};
    local $ENV{TMPDIR} = "/tmp";
    local $ENV{LANG} = "en_US.UTF-8";
    local $!;
    if(open(my $fh, "bash < $fn 2>&1|")){
        local $/;
        my $result = <$fh>;
        close($fh);
        my ($err, $errno) = ($?, $!);
        unlink $fn;
        return "[ERROR] errno: $errno, exit code: ".($err >> 8).", signal: ".($err & 127).", output: $result" if $err or $errno;
        return $result;
    }
    return "[ERROR] problem running: $!";
}

sub perl_d8d2 {
    my ($t_args) = @_;
    return "[ERROR] need an actual perl program, size=0" unless length($t_args//"");
    return utils::daemon(sub {
        # full "freedom", sub-process anyways, and dockerized!
        no strict;
        no warnings;
        eval $t_args->[0];
        die $@ if $@
    });
}

sub read_c5a3 {
    my ($t_args) = @_;
    my $file = utils::trim($t_args->[0]);
    if (open(my $fh, '<', $file)) {
        local $/;
        my $content = <$fh>;
        close($fh);
        return $content // "";
    }
    return "[ERROR] file not found: $file: $!";
}

sub write_edf5 {
    my ($t_args) = @_;
    my $path = utils::trim($t_args->[0]);
    log::info("WRITE: $path");
    open(my $fh, '>', $path)
        or die "Cannot write to $path: $!";
    print {$fh} $t_args->[1];
    if(!close($fh)){
        return "[ERROR] problem running tool 'write' for $path: $!";
    }
    return "[OK] written to $path";
}

sub grep_6629 {
    my ($t_args) = @_;
    my $path = $t_args->[0];
    my $pattern = $t_args->[1];
    return "[ERROR] not enough properties" unless length($path//"") and length($pattern//"");
    local $ENV{PATH} = $::ORIG_ENV{PATH};
    local $!;
    open(my $fh, "-|", "grep", $pattern, $path)
        or return "[ERROR] cannot run grep: $!";
    local $/;
    my $result = <$fh>;
    close($fh);
    my ($err, $errno) = ($?, $!);
    return "[ERROR] errno: $errno, exit code: ".($err >> 8).", signal: ".($err & 127).", output: $result" if $err or $errno;
    return $result // "";
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
