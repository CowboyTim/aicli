# AI-CLI Project Analysis

## Overview
AI‑CLI is a Perl‑based command‑line interface for interacting with various LLM providers (Cerebras, OpenRouter, OpenAI, Groq, Anthropic, Bedrock, Lemonade/ROCm). It provides an interactive chat with tool support (bash, perl, file read/write, grep), session persistence, and Docker‑friendly deployment.

## Core Components
- **ai.pl** – main script handling chat loop, API requests, tool execution, session management.
- **aicli.sh** – Bash wrapper that runs ai.pl inside a Docker container with volume mounts, SSH/GPU forwarding, etc.
- **Dockerfile** – Alpine‑based image installing Perl dependencies and copying ai.pl.
- **TODO.md** – roadmap of enhancements.
- **AGENTS.md** (this file) – documentation of the project structure and current status.
- **ai/** – prompt templates.
- **t/** – test directory.

## Features
- Multi‑provider support with automatic API‑key detection.
- Streaming and non‑streaming modes; SSE parsing for real‑time token output.
- Built‑in tools: bash, perl, read, write, grep (with easy extension).
- Session storage per chat (history, prompt, message state, model override).
- Command interface (`/exit`, `/model`, `/session`, `/tools`, `/files`, etc.).
- Debug mode and logging.

## Current Development Focus (from TODO.md)
**High Priority**
1. Streaming Responses & Token Statistics – improve SSE parsing, add usage stats, TTFT/TPOT metrics.
2. Enhanced Streaming Experience – thinking‑tag coloring, incremental Markdown rendering, reliable tool interruptions during stream.
3. Enhanced Error Handling & Resilience – retry with backoff, better messages, rate‑limit handling.
4. Tool System Improvements – sandboxed bash, configurable allow‑lists, new tools (web search, file edit, git), syntax‑highlighted diff viewer.
5. Configuration Management – JSON/YAML config files, per‑session/global config, secure API‑key storage.

**Medium Priority**
- Session tagging, search, summarization, export/import, persistence across restarts.
- Git integration (AI‑generated commit messages, branch suggestions).
- IDE‑like features: code completion, refactoring, project context awareness.
- LLM‑initiated clarification questions + user response incorporation.
- Plan mode – AI outlines steps before execution.
- UI upgrades: syntax highlighting for code blocks, better tool output formatting, custom keybindings, progress indicators, Markdown viewer (glow/lowden), optional TUI with panes.

**Low Priority / Exploration**
- Multi‑modal support (images, audio).
- Agent collaboration (multiple AIs working together, registry/discovery).
- Performance: cache API responses, optimize session I/O, consider lightweight DB for storage.

## Completed Items
- Basic interactive shell with history.
- Multi‑provider support (Cerebras, OpenRouter, etc.).
- Built-in tools: bash, grep, file operations.
- Session persistence per chat context.
- Dockerized deployment (via provided Dockerfile and aicli.sh).

---
*Analysis generated on 2025-09-16*