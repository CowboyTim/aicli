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