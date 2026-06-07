# TODO: AI Coding Agent Enhancements

This file outlines potential improvements and features for the AI coding agent (ai.pl).

## High Priority

1. **Streaming Responses & Token Statistics**
   - Currently sets `stream => 1` but only prints deltas when `$ORIG_ENV{AI_STREAM}` is set.
     * Ensure proper SSE parsing: handle `[DONE]` correctly, ignore empty lines, and validate JSON per event.
   - Add token usage statistics from llama.cpp API:
        a. For non-streaming mode (`AI_STREAM=0`): extract `usage` field (prompt_tokens, completion_tokens, total_tokens) already present in response; display after generation as: `[Usage: Prompt X, Generated Y, Total Z]`.
        b. For streaming mode (`AI_STREAM=1`):
              - Measure wall-clock time from request start to final chunk receipt for end-to-end latency (TTFT and TPOT derivable).
                  * Record:
                       t0 = Time::HiRes::gettimeofday() before HTTP POST
                       First token arrival: note timestamp when first delta received.
                            Last non-[DONE] event after processing deltas, then maybe look ahead for a final SSE JSON that includes usage?
                   llama.cpp may not send per-event counts; however:
                     - If server supports `include_usage=true` (OpenAI extension) or similar in streamed chunks: extract from last chunk before [DONE].
                    Otherwise fallback to approximate by counting tokens of generated response via same tokenizer? Not feasible without model.
              Instead we will note that llama.cpp can be built with metrics and may return:
                     Each SSE event might include a `"timings": {"predicted_n":..., "prompt_time_ms":...}` etc. (check server build options).
                    If present, accumulate or show last values per token? Actually these are cumulative.
              Plan: After generation ends,
                   - Print final stats line like: `[Usage: Prompt P, Generated C, Total T | TTFT: Xms, TPOT: Yms/token, T/S: Z]`
                     Where:
                         *TTFT* = Time to First Token (first_delta_timestamp - t0)
                         *TPOT* = Average Time Per Output Token = (last_token_timestamp - first_delta_timestamp) / C   if we had per-token times or approximate with total generation time divided by token count.
                   To get accurate TPOT/T/S would require either:
                       i. Server returns `timings.predicted_n` incrementally? Actually each event may contain cumulative predicted tokens so far => then T.S = incremental_predicted / (event_time - t0) at that point; but we'd need to print live updating stats which is distracting.
                  ii. Or simpler: after completion compute:
                        Total generation time for output = timestamp_of_last_event_with_content - first_token_timestamp
                         Then T.S = C / (generation_time)
                      We don't have per-event content timestamps unless we record them.

        Implementation path to add now in chat_completion():
            a. Use Time::HiRes if available.
            b. In streaming block:
                    my $t0 = [Time::HiRes::gettimeofday] if $ORIG_ENV{AI_STREAM};
                    my ($first_t, $last_content_t) = (undef);
                    foreach event ...
                        if first delta and not defined $first_t: set $first_t = [Time::HiRes::gettimeofday];
                        always update $last_content_t = [Time::HiRes::gettimeofday] upon printing any delta.
                    After loop over events, before finishing stream handling:
                       if defined $first_t and defined $last_content_t {
                            my $gen_secs = Time::HiRes::tv_interval($first_t, $last_content_t);
                            # Note: token count C unknown! Need either from usage or approximate via splitting response by tokenizer (heavy).
                        }
            c. Because we lack exact per-event token counts without heavy lifting:
                  Option 1: If server includes a `"usage"` field in the final SSE chunk before [DONE] -> use completion_tokens from that.
                         Some implementations do send an extra "usage" object as last meaningful chunk (see llama.cpp PR #...).
                        We'll parse each event JSON for existence of top-level `usage` and if found, store it; usage then likely reflects cumulative so far? Actually final usage should be total. So we can break when seeing a non-empty usage after having seen at least one token?
                  Option 2: Fall back to estimating tokens via splitting the response on whitespace or using simple regex (not accurate but indicative).
            d. Additionally, if server sends per-event timings object with cumulative predicted tokens and wall time then:
                         Let event include { "timings": { "predicted_n": N, "t": T_ms } }
                          Then instantaneous T/S approx = N / (T/1000)   -> but note this is cumulative so we can compute incremental by keeping previous.
                     We could display a live updating T/S in corner? Not required; maybe just final average.

          Given the complexity, initial step:
              - Display after generation completes: 
                    [Usage: Prompt tokens=?, Generated tokens=C (estimated via split on non-whitespace?), Total=? ]
                          Time for prompt: ?ms   -> actually we don't have that without separate metric or from usage.prompt_time if server provides.
                          Generation speed: X token/sec

              Where:
                  *Prompt tokens*: In streaming mode we cannot get easily unless the very first SSE event includes usage with prompt_tokens (unlikely) OR we do a separate non-streaming call just to count input? Wasteful.

          Better approach for llama.cpp specifically when used as backend:
                Since this agent targets llama.cpp instance, and given that many frontends work by having two modes: 
                    - Either disable streaming to get usage,
                    - Or if they want both streaming and usage then the server must support returning usage in stream (see: https://github.com/ggerganov/llama.cpp/pull/... )  

            Therefore we will note that updating the agent to properly utilize llama.cpp's extended streaming features requires:
                 a. Checking if target llama.cpp was built with `-DBUILD_SERVER=ON` and supports OpenAI compatible `/v1/chat/completions` with stream.
                    Actually it does by default? 
                b. If server compiled with `-DGGML_METAL=on` or others doesn't affect this; but to get token timing in SSE we might need specific commit.

            Let's assume the llama.cpp instance in use is recent enough that when streaming:
                 - It may include a `"usage"` field only in the final chunk (after which still comes `[DONE]` OR instead of [DONE]? Check: actually OpenAI style does not put usage in stream; they have separate non-stream endpoint for usage.)

            Conclusion from quick research memory: 
                    The standard OpenAI API chat completions with stream=true does NOT include usage in any event. Usage only available when stream=false.
                      (See: https://platform.openai.com/docs/api-reference/chat/streaming )

            Therefore to get token counts we have two options:
                   Option A: User must accept not getting exact usage while streaming; or
                   Option B: We make an additional lightweight non-streaming call with same messages just prior to streaming? That duplicates work but gives us prompt tokens and also would allow computing completion tokens if we subtract? 
                             Actually no, because generation may be nondeterministic (temperature>0) so two calls differ.

            Given this:
                  We might decide: when user wants both streaming AND token stats -> they must set AI_STREAM=0 to get usage after; OR only show estimated via word count and apologize inaccuracy for tokens/s but still measure wall time of generation phase.


2. **Enhanced Streaming Experience**
   - Proper handling of thinking tags (`<think>...</think>`) during streaming:
        * Optionally colorize thinking tag content (e.g., dim gray or blue) to distinguish from final answer.
        * If the model corrects/overwrites previous text within thinking tags (rare but possible), update the displayed buffer accordingly using terminal control sequences (carriage return, erase line, etc.) for a smooth experience. Note: This requires buffering the current thinking segment and redrawing when changes occur upstream of the cursor.
   - Render markdown in real-time where feasible:
        * Use a CPAN markdown formatter (e.g., `Text::Markdown` or `Markdown::Perl`) to convert accumulated chunks to HTML/ANSI for display, but note token-by-token makes incremental rendering challenging. Instead buffer until we have a complete Markdown block (e.g., after a newline that ends a paragraph) then render and replace the buffered portion in the terminal using cursor movements.
        * For thinking tags: if they contain markdown, apply markdown formatting within the thinking tag's colored output.
   - Ensure streaming works reliably with tool interruptions:
        * When a tool command is invoked (via /tool syntax), pause the streaming display, execute the tool, then inject the result as a user message and continue streaming the assistant's response.

3. **Enhanced Error Handling & Resilience**
    - Add retry mechanisms with exponential backoff for API calls.
    - Better error messages and recovery from network failures.
    - Handle rate limiting gracefully.

4. **Tool System Improvements**
    - Sandboxed execution for bash tool (e.g., using firejail or containers).
    - Allow configuration of allowed commands/directories for security.
    - Add more built-in tools: web search, file editing, git operations.
    - Proper diff (colored) viewer: Enhance diff output with syntax highlighting and side-by-side views.

5. **Configuration Management**
    - Introduce a config file (JSON/YAML) in addition to environment variables.
    - Support per-session and global configurations.
    - Allow saving API keys securely (with encryption option).

## Medium Priority

6. **Session Management Enhancements**
    - Session tagging and searching.
    - Automatic session summarization or title generation.
    - Session export/import (including history and context).
    - Session persistence across container restarts.

7. **Integration & Workflow Features**
    - Git integration: AI-assisted commit messages, branch suggestions.
    - IDE-like features: code completion, refactoring suggestions via AI.
    - Project context awareness (understand repo structure, dependencies).
    - Questions from LLM + answer and respond: Enable the AI to ask clarifying questions when uncertain, then incorporate user responses.
    - Plan mode: Allow the AI to outline a step-by-step execution plan before proceeding with tasks.

8. **User Interface Improvements**
    - Syntax highlighting for code blocks in responses.
    - Better formatting of tool outputs (tables, JSON views).
    - Customizable keybindings and command aliases.
    - Progress indicators for long-running operations.
    - Markdown viewer when needed: Render markdown documents in the terminal using external tools (e.g., glow, lowdown) for rich previews.
    - TUI (Text User Interface): Explore optional full-screen interface with multiple panes (chat, files, tools) using a library like Curses::UI.

9. **Testing & Quality Assurance**
    - Expand test coverage beyond session management.
    - Add unit tests for core functions (chat_setup, execute_tool, etc.).
    - Implement end-to-end tests with mock AI providers.
    - Set up CI/CD pipeline for automated testing.

## Lower Priority / Exploration

10. **Multi-modal Support**
    - Extend to handle image inputs (for vision-capable models).
    - Audio input/output possibilities.

11. **Agent Collaboration**
    - Allow multiple AI agents to work together on complex tasks.
    - Agent registry and discovery mechanism.

12. **Performance Optimization**
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
- [x] Project analyzed and documentation added to AGENTS.md
