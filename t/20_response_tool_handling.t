#!/usr/bin/perl
use strict; use warnings;

use Test::More;
use Data::Dumper;
use FindBin;
use File::Temp;
use File::Path qw(make_path rmtree);
use lib "$FindBin::Bin/..";
local $Data::Dumper::Sortkeys = 1;
no warnings 'once';

$::DEBUG = ($ENV{DEBUG}//"0") == "1"?1:0;

my $btmpdir = File::Temp::tempdir("aicli_XXXXXXX", DIR => "/tmp", CLEANUP => 1);
make_path($btmpdir);
print "# $btmpdir\n";

use_ok("ai");

{
    my ($n, $p, $r) = ai::handle_llm_response(\"");
    is($n, 0, 'tools: 0');
    is($p, 0, 'pos: 0');
    is_deeply($r, [], 'r: 0');
}

{
    my ($n, $p, $r) = ai::handle_llm_response();
    is($n, 0, 'tools: 0');
    is($p, 0, 'pos: 0');
    is_deeply($r, [], 'r: 0');
}

{
    my $v = <<EOp
<think>
We are going to update the README.md file with a brief description of the project.
 Since the current README.md only contains "1", we will replace it with a proper README.

 Let's write a new README.md that includes:
 - Project name and description
 - Features
 - Installation/Usage (briefly, since there's a Docker setup)
 - How to run
 - etc.

 However, note that the user said: "put this in the README.md", but didn't specify what "this" is.
 Looking at the history, the user asked to analyze the files in the dir, and then we did.

 Since the user didn't specify the content for the README, I will assume they want a standard README
 that describes the project based on our analysis.

 Let's create a README.md with the following content:

</think>

///WRITE_edf5+EO_d0684c052bf3d9c503a8+EO_ecdeef376b1647fa824a
README.md
EO_d0684c052bf3d9c503a8
# AI-CLI: A Perl-Based Command-Line Interface for LLMs

AI-CLI is an interactive command-line chat interface for interacting with various Large Language Model (LLM) providers. It supports streaming responses, tool usage (bash, perl, file operations, grep), session persistence, and multi-provider compatibility.

## Features

- **Multi-provider Support**: Works with Cerebras, OpenRouter, OpenAI, Groq, Anthropic, Bedrock, and local servers (like llama.cpp via Lemonade/ROCm)
- **Streaming & Non-streaming Modes**: Real-time token output with Server-Sent Events (SSE) parsing
- **Built-in Tools**:
  - `/bash` - Execute bash commands
  - `/perl` - Run Perl scripts
  - `/read` - Read file contents
  - `/write` - Write/overwrite files
  - `/grep` - Search files with regex patterns
- **Session Management**: Persistent chat histories, per-session configuration, and model switching
- **Docker-friendly**: Runs as non-root user with volume mounts for workspace and SSH agent forwarding
- **Extensible Tool System**: Easy to add new tools following the existing pattern
- **Customizable Prompts**: Switch between different system prompt templates (e.g., coder, default)

## Quick Start

### Using Docker (Recommended)
```bash
# Clone this repository
git clone <repository-url>
cd <repository-directory>

# Run with Docker (adjust environment variables as needed)
./aicli.sh
```

### Direct Installation
1. Ensure you have Perl and required dependencies installed:
   ```bash
   # On Alpine/Debian-based systems:
   apk add perl perl-json perl-lwp-protocol-https perl-term-readline-gnu perl-json-xs perl-net-curl
   # or
   apt-get install perl libjson-perl libwww-perl libterm-readline-gnu-perl libjson-xs-perl libnet-curl-perl
   ```

2. Copy `ai.pl` and the `ai/` directory to your desired location

3. Set required environment variables:
   ```bash
   export AI_API_KEY="your-api-key-here"
   export AI_PROVIDER="openrouter"  # or cerebras, openai, etc.
   export AI_MODEL="model-name"     # optional, provider-dependent
   ```

4. Run the script:
   ```bash
   perl ai.pl
   ```

## Usage

Once running, you can:
- Chat naturally with the AI
- Use commands prefixed with `/`:
  - `/exit` or `/quit` - Leave the chat
  - `/clear` - Clear conversation history
  - `/history` - View full chat history
  - `/tools` - List available tools
  - `/session list` - See all chat sessions
  - `/session create <name>` - Create a new session
  - `/model <model-name>` - Switch AI model for current session
  - `/files <pattern>` - Add matching files to conversation context
- Invoke tools in your prompts using the syntax:
  ```
  ///TOOL_{HEX}+{T1}+{T2}
  {{path}}
  {T1}
  {{content}}
  {T2}
  TOOL_{HEX}
  ```

## Configuration

Configuration is primarily done through environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `AI_API_KEY` | API key for your chosen provider | (required) |
| `AI_PROVIDER` | Provider name (cerebras, openrouter, openai, groq, anthropic, bedrock, lemonade) | auto-detected from key |
| `AI_MODEL` | Model identifier | provider-dependent |
| `AI_TOKENS` | Max tokens per response | 8192 |
| `AI_TEMPERATURE` | Sampling temperature | 0 |
| `AI_STREAM` | Enable streaming (1) or not (0) | 1 |
| `AI_SESSION` | Session name | auto-generated UUID |
| `AI_DIR` | Base directory for data storage | `~/.aicli` |
| `AI_PROMPT_TEMPLATE` | System prompt template | `coder` |
| `DEBUG` | Enable debug logging | 0 |

## Project Structure

- `ai.pl` - Main application logic
- `aicli.sh` - Docker wrapper script with volume/device forwarding
- `Dockerfile` - Alpine-based container image build instructions
- `ai/` - System prompt templates (coder, default)
- `t/` - Test suite
- `TODO.md` - Roadmap of planned enhancements
- `AGENTS.md` - Technical analysis of the project
- `MEMORY.md` - Additional project notes

## Development

See [TODO.md](TODO.md) for current development priorities including:
- Enhanced streaming with token statistics (TTFT/TPOT)
- Thinking tag visualization during streaming
- Improved error handling and retry mechanisms
- Sandboxed tool execution
- Configuration file support (JSON/YAML)

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

EOF_d0684c052bf3d9c503a8
EO_ecdeef376b1647fa824a
WRITE_edf5
```
EOp
    ;
    my $tmpdir = File::Temp::tempdir('tool_XXXXXX', DIR => $btmpdir, CLEANUP => 1);
    make_path($tmpdir);
    chdir($tmpdir) or die $!;
    print "# in $tmpdir\n";
    my @oklist;
    my ($n, $p, $r) = ai::handle_llm_response(\$v, sub {push @oklist, $_[0]});
    is($n, 1, 'tools: 1');
    is($p, undef, 'pos: undef');
    is_deeply($r, [{
        'content' => '[WRITE_edf5 RESULT_d170b4e6bb11cfd550aa
[OK] written to README.md
RESULT_d170b4e6bb11cfd550aa]',
        'role' => 'user'
    }], 'r: 0') or print Dumper($r);
    is_deeply(\@oklist, [
        "${colors::yellow_color1}\[TOOL WRITE_edf5(...))]${colors::reset_color}\n",
        "${colors::green_color}\[WRITE_edf5 RESULT_d170b4e6bb11cfd550aa
[OK] written to README.md
RESULT_d170b4e6bb11cfd550aa]${colors::reset_color}\n"
    ], "print ok printer") or print Dumper(\@oklist);
    chdir("/");
    rmtree($tmpdir);
}

{
    my $v = q{
<think>
We need to list files under .git/ using Perl instead of Bash/unix tools. So we should write a Perl script that reads directory .git and prints entries (maybe like ls -la). Use opendir, readdir, stat for each entry to get permissions, nlink, uid, gid, size, mtime, name.

We need to output similar format: total blocks? Could compute but maybe just list. Simpler: print each file with details akin to ls -l.

Let's write a Perl script and execute it via the perl tool (since we have PERL_d8d2). We'll produce code that does opendir('.git'), then for each entry skip . and .., get stat, format mode, nlink, uid, gid, size, month day time/year, name.

We need to run it. Use ///PERL_d8d2+EO_... code EO_... PERL_d8d2

Let's craft the Perl script:

```perl
#!/usr/bin/perl
use strict;
use warnings;
my $dir = '.git';
opendir(my $dh, $dir) or die "Cannot open $dir: $!";
my @entries = grep { !/^\.\.?$/ } readdir($dh);
closedir $dh;

# For total blocks (like ls -l), we can sum blocks from stat
my $total_blocks = 0;
my @files;
foreach my $e (@entries) {
    my $path = "$dir/$e";
    my ($dev,$ino,$mode,$nlink,$uid,$gid,$size,$atime,$mtime,$ctime,$blksize,$blocks) = stat($path);
    $total_blocks += $blocks;
    push @files, [$e, $mode, $nlink, $uid, $gid, $size, $mtime];
}
printf "total %d\n", $total_blocks/2; # ls shows blocks in 1K? Actually ls -l total is in 1K blocks? In Linux it's 1K blocks. stat blocks are 512-byte units. So total/2 gives K.
foreach my $f (@files) {
    my ($name,$mode,$nlink,$uid,$gid,$size,$mtime) = @$f;
    my $perms = sprintf("%04o", $mode & 07777);
    # convert to symbolic? We'll just output octal for simplicity.
    my ($dev,$ino,$rdev) = (stat("$dir/$name"))[0,1,6]; # not needed
    my $uid_num = $uid;
    my $gid_num = $gid;
    # get user/group names via getpwuid/getgrgid
    my $user = getpwuid($uid) || $uid;
    my $group = getgrgid($gid) || $gid;
    my $time = localtime($mtime);
    my ($month,$day,$time_part,$year) = split ' ', $time;
    # adjust: if year != current year, show year else time
    my ($sec,$min,$hour,$mday,$mon,$year_now,$wday,$yday,$isdst) = localtime(time);
    my $time_display = ($year_now - (1900+$year)) ? sprintf("%-4s",$year+1900) : $time_part;
    printf "%s %3d %-8s %-8s %8d %s %2s %4s %s\n",
        $perms, $nlink, $user, $group, $size,
        $month, $day, $time_display, $name;
}
```

But we need to ensure correct formatting. Simpler: just output like `ls -l` using `stat` and `printf`. Might be okay.

Let's produce the script content then run via PERL tool.

We'll embed in a heredoc marker EO_... Use unique markers.

Proceed.


</think>
///PERL_d8d2+EO_929b2e8d61111fac138f
#!/usr/bin/perl
use strict;
use warnings;

my $dir = '.git';
opendir(my $dh, $dir) or die "Cannot open $dir: $!";
my @entries = grep { !/^\.\.?$/ } readdir($dh);
closedir $dh;

# Compute total blocks (in 1K units like ls -l)
my $total_blocks = 0;
my @file_info;
foreach my $e (@entries) {
    my $path = "$dir/$e";
    my ($dev,$ino,$mode,$nlink,$uid,$gid,$size,$atime,$mtime,$ctime,$blksize,$blocks) = stat($path);
    $total_blocks += $blocks;
    push @file_info, {
        name   => $e,
        mode   => $mode,
        nlink  => $nlink,
        uid    => $uid,
        gid    => $gid,
        size   => $size,
        mtime  => $mtime
    };
}
printf "total %d\n", $total_blocks/2;  # convert 512-byte blocks to 1K

foreach my $f (@file_info) {
    my ($name,$mode,$nlink,$uid,$gid,$size,$mtime) = @$f{qw(name mode nlink uid gid size mtime)};
    my $perms = sprintf("%04o", $mode & 07777);
    # Convert to symbolic permission string
    my $sym_perms = '';
    $sym_perms .= ($mode & 00400) ? 'r' : '-';
    $sym_perms .= ($mode & 00200) ? 'w' : '-';
    $sym_perms .= ($mode & 00100) ?
        (($mode & 004000) ? 's' : 'x') :
        (($mode & 004000) ? 'S' : '-');
    $sym_perms .= ($mode & 00040) ? 'r' : '-';
    $sym_perms .= ($mode & 00020) ? 'w' : '-';
    $sym_perms .= ($mode & 00010) ?
        (($mode & 002000) ? 's' : 'x') :
        (($mode & 002000) ? 'S' : '-');
    $sym_perms .= ($mode & 00004) ? 'r' : '-';
    $sym_perms .= ($mode & 00002) ? 'w' : '-';
    $sym_perms .= ($mode & 00001) ?
        (($mode & 001000) ? 't' : 'x') :
        (($mode & 001000) ? 'T' : '-');

    my $user = getpwuid($uid) || $uid;
    my $group = getgrgid($gid) || $gid;

    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($mtime);
    my @months = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
    my $month = $months[$mon];
    my $time_field;
    my ($now_sec,$now_min,$now_hour,$now_mday,$now_mon,$now_year,$now_wday,$now_yday,$now_isdst) = localtime(time);
    if ($year == $now_year) {
        $time_field = sprintf("%02d:%02d", $hour, $min);
    } else {
        $time_field = sprintf("%-4s", $year+1900);
    }

    printf "%s %3d %-8s %-8s %8d %s %2s %4s %s\n",
        $sym_perms, $nlink, $user, $group, $size,
        $month, $mday, $time_field, $name;
}
EO_929b2e8d61111fac138f
PERL_d8d2
EOp
}
    ;
    my $tmpdir = File::Temp::tempdir('tool_XXXXXX', DIR => $btmpdir, CLEANUP => 1);
    make_path($tmpdir);
    chdir($tmpdir) or die $!;
    mkdir(".git");
    print "# in $tmpdir\n";
    my @oklist;
    my ($n, $p, $r) = ai::handle_llm_response(\$v, sub {push @oklist, $_[0]});
    is($n, 1, 'tools: 1');
    is($p, undef, 'pos: undef');
    is_deeply($r, [{
        'content' => '[PERL_d8d2 RESULT_d170b4e6bb11cfd550aa
total 0

RESULT_d170b4e6bb11cfd550aa]',
        'role' => 'user'
    }], 'r: 0') or print Dumper($r);
    is_deeply(\@oklist, [
        "${colors::yellow_color1}\[TOOL PERL_d8d2(...))]${colors::reset_color}\n",
        "${colors::green_color}\[PERL_d8d2 RESULT_d170b4e6bb11cfd550aa
total 0

RESULT_d170b4e6bb11cfd550aa]${colors::reset_color}\n",
    ], "print ok printer") or print Dumper(\@oklist);
    chdir("/");
    rmtree($tmpdir);
}


done_testing();

END {
    rmtree($btmpdir) if defined $btmpdir;
}
