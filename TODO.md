# TODO: AI Coding Agent Enhancements

This file outlines potential improvements and features for the AI coding agent (ai.pl).

## High Priority

1. **Streaming Responses**
   - Implement streaming output from AI providers to improve user experience during long generations.
   - Currently, responses are fetched in a single blocking call.

2. **Enhanced Error Handling & Resilience**
   - Add retry mechanisms with exponential backoff for API calls.
   - Better error messages and recovery from network failures.
   - Handle rate limiting gracefully.

3. **Tool System Improvements**
   - Sandboxed execution for bash tool (e.g., using firejail or containers).
   - Allow configuration of allowed commands/directories for security.
   - Add more built-in tools: web search, file editing, git operations.

4. **Configuration Management**
   - Introduce a config file (JSON/YAML) in addition to environment variables.
   - Support per-session and global configurations.
   - Allow saving API keys securely (with encryption option).

## Medium Priority

5. **Session Management Enhancements**
   - Session tagging and searching.
   - Automatic session summarization or title generation.
   - Session export/import (including history and context).
   - Session persistence across container restarts.

6. **Integration & Workflow Features**
   - Git integration: AI-assisted commit messages, branch suggestions.
   - IDE-like features: code completion, refactoring suggestions via AI.
   - Project context awareness (understand repo structure, dependencies).

7. **User Interface Improvements**
   - Syntax highlighting for code blocks in responses.
   - Better formatting of tool outputs (tables, JSON views).
   - Customizable keybindings and command aliases.
   - Progress indicators for long-running operations.

8. **Testing & Quality Assurance**
   - Expand test coverage beyond session management.
   - Add unit tests for core functions (chat_setup, execute_tool, etc.).
   - Implement end-to-end tests with mock AI providers.
   - Set up CI/CD pipeline for automated testing.

## Lower Priority / Exploration

9. **Multi-modal Support**
   - Extend to handle image inputs (for vision-capable models).
   - Audio input/output possibilities.

10. **Agent Collaboration**
    - Allow multiple AI agents to work together on complex tasks.
    - Agent registry and discovery mechanism.

11. **Performance Optimization**
    - Cache frequent API responses where appropriate (e.g., model listings).
    - Optimize session file I/O for large histories.
    - Consider using a lightweight database for session storage.

## Completed Items (Reference)
- [x] Basic interactive shell with history
- [x] Multi-provider support (Cerebras, OpenRouter, etc.)
- [x] Built-in tools: bash, grep, file operations
- [x] Session persistence per chat context
- [ ] Dockerized deployment

---
*Last updated: $(date)*