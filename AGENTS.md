# Tech Stack Analysis: AI Chat CLI

## Overview
`ai.pl` is a command-line interface for interacting with various AI chat models using Perl.

## Core Technology Components

### Language & Runtime
- **Primary Implementation**: Perl (version compatible with modern versions)
- **Key Features Used**:
  - `strict`, `warnings`
  - Dynamic module loading via eval/require pattern
  - Object-oriented JSON handling (`JSON::XS`)
  - HTTP client integration (`WWW::Curl::Easy`)

### Dependencies & Modules

#### Direct CPAN/Cpanm Packages:
1. **Essential**:
   - `Data::UUID`: Session ID generation fallback
   - `Pod::Usage`: Help/usage message formatting (commented but present)
   
2. **Runtime Required** (from Dockerfile and code):
   - `perl-json` / `JSON::XS`: JSON encoding/decoding for API communication
   - `WWW::Curl::Easy`: HTTP client wrapper around libcurl with IPv6 preference
   - `Term::ReadLine` + `Term::ReadLine::Gnu`: Interactive CLI features (history, tab completion)
   - `File::Temp`: Temporary file handling in tool execution (`/bash`)
   - `File::Path`: Directory tree removal for session deletion

3. **Optional Enhancement**:
   - Additional modules loaded dynamically based on feature usage
   
### Containerization & Build System
- **Container Runtime**: Docker with multi-stage build support (buildx)
- **Base Image**: Alpine Linux (latest at time of creation)
- **Build Command**: `docker buildx build --load --tag ai .`
- **Entry Point Script**:
  ```Dockerfile
  FROM alpine
  RUN apk add --no-cache perl perl-json perl-lwp-protocol-https perl-term-readline-gnu perl-json-xs
  COPY ai.pl /
  RUN perl -cw /ai.pl   # Syntax check during build
  ENV HOME=/ai          # User environment within container (matches docker run volume)
  USER nobody           # Security: non-root user execution
  WORKDIR /ai           
  VOLUME ["/ai"]         # Persistent storage for sessions/configs/prompts via bind mount or named volumes in compose/run commands.
   ENTRYPOINT ["/usr/bin/perl", "/ai.pl"]
 ```

### AI Provider Integration Architecture

#### Supported Providers (auto-detected by API key prefix):
| Provider    | Key Prefix  | Endpoint Base URL                          |
|-------------|:-----------:|--------------------------------------------|
| Cerebras   | `csk-`     | https://api.cerebras.ai                   |
| OpenRouter | `sk-or-`   | https://openrouter.ai/api                 |
| OpenAI      |  (standard)| Not explicitly set in config - likely standard pattern but code shows generic handling   
             *(Note: Code treats as needing 'v1/' prefix for most providers except Anthropic)* |

#### Provider Configuration Logic:
```perl
# In chat_setup() sub routine:

%PROVIDERS = (
    cerebras => { url          ->'https://api.cerebras.ai', key_prefix      ,->  csk- },
 ...
);
```
*Actual URL construction:*
1. If `AI_LOCAL_SERVER` is set: Use that value directly, provider detection disabled
2. Else:
   - Attempt prefix-based auto-detection from API key against `%PROVIDERS`
   - Fall back to explicitly configured `$ORIG_ENV{AI_PROVIDER}`
   - Normalize endpoint URL (strip trailing slash)
   - Set version path (`v1/`) based on provider type 
     *Exception:* Anthropic uses root `/` instead of `v1/` for API paths

#### Supported Models:
Provider-dependent, fetched dynamically from `{endpoint}/models or /chat/models`
- Session-specific model persistence in `$SESSION_DIR/model`

### CLI & User Experience Features

#### Interactive Shell Infrastructure (`Term::ReadLine`)
* Implementation Details:*
  - Forces GNU Readline backend via `PERL_RL=Gnu` environment
  - Custom UTF8 handling with `_utf8_on/off`
  - History saved per session in `$SESSION_DIR/history`

##### Tab Completion System:
- Command hierarchy: `/command subcmd args...`
- Contextual completion for commands/files/sessions via `attempted_completion_function => \&chat_word_completions_cli`  

#### Session Management
* Directory Structure:*
```
$AI_DIR (default ~/.aicli)/
├── sessions/
│   ├── session-{uuid}/           # AI_SESSION directory per chat context 
│   │   ├─ history               -> Raw readline input/output stream       
       └─── prompt              --> Current system message for this model instance    
         and status                => JSON Lines array of {role,content} turns (user/assistant/system)
```

##### Session Commands:
`/session [list|create NAME|delete NAME|switch NAME]`

### Extensibility Features

#### Built-in Tools Interface (`%TOOLS`)
Available to AI models via special response syntax `/tool args`:

1. **Command Execution**: 
   - Tool: `bash <command>`
   - Action: Executes in subprocess, captures STDOUT/STDERR combined as result text for context injection

2. **File Operations:**
    *Read:* Returns file contents or error string      (path relative to CWD unless absolute)     → Used by AI models during reasoning steps needing filesystem access
       Write:** Truncates and writes content   [used when model needs persist artifacts]

3.  Search (`grep`):
          Uses `system grep -r --binary-files=without-match`
         Returns raw matching lines or error

#### Prompt Engineering System:
*Template Location:* `$FindBin::Bin/ai/{prompt_name}` (defaults to 'default' prompt)
- Stored per-session: copied on session init unless override via environment
  Supports hot-swapping with `/prompt name` command  


### Security Considerations Implemented

1. **Environment Sanitization:**    Early BEGIN block clears `%ENV`, saves original state as backup for config reload later ($ORIG_ENV usage)
2. Principle of Least Privilege: Docker container runs UID/GID `nobody`
3 Input Validation:* 
     - Path traversal mitigated in file tools (though absolute paths permitted)   -- Could be improved with chroot/jail but accepts host-directory mounting as primary use case     


### Deployment & Usage Patterns

#### Standard Workflow:
```bash
# Persistent data volume example naming convention from README/docker usage comment: 
docker run \
    -v ai_data:/ai \                # Named Docker volume (alternative to bind-mount for portability)   OR\
    -v ~/.myaiconfig:/ai           Bind mount host directory containing config/creds at /ai inside ctr     --rm                          Cleanup container on exit 
      -it                            Interactive terminal allocation required for TUI                    ai                         # Image tag from build command above                  

# Environment Variable Configuration (inside or passed via docker run -e)
AI_API_KEY=csk-xxxxxxxx...         Cerebras key example triggers auto-detection   AI_MODEL=llama-3-sonnet-large-32k-model-v2    
```

#### Development Setup:
As documented in README prerequisites for native Perl execution:    `sudo apt install libjson-xs-perl libterm-readline-gnu-perl ...`


### Observed Limitations & Improvement Opportunities

*Current State Assessment:*

1. Tool Result Injection:*
   Currently appends raw tool output as a user message (role=user) containing formatted block:
       ```
         [TOOL RESULT from bash: ls -la
total 0 ...
```    *May benefit structural typing or special role/tool-result message format for clearer model prompting*

2 Streaming Implementation:*     Not currently implemented despite being mentioned in task request. All requests use non-streaming (`stream => JSON::XS->false()`)
        Would require refactoring `chat_completion` to handle incremental chunks via event loop while preserving tool interception capability  

3 Error Resilience:
      Network failures during streaming not handled; single monolithic response parsing assumes HTTP 200 OK only    
         Consider adding retries with backoff, circuit breaker pattern for flaky connections         


This analysis covers the substantive technical components observed through file inspection. The system demonstrates solid Perl practices leveraging CPAN effectively while maintaining containerized deployability as a versatile LLM client interface specializing in developer workflow augmentation via builtin tool-use capabilities.

