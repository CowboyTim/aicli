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
                    after printing delta & appending to $resp:
                         $last_content_t = [Time::HiRes::gettimeofday];   # update each time we get content
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


   - **Proposed immediate implementation steps** (to be noted as sub-todos):
        1. Add `use Time::HiRes;` if available.
        2. In chat_completion():
                my $t0 = [Time::HiRes::gettimeofday];
                ...
                Inside SSE loop:
                    when we see first delta content: set $first_t = [Time::HiRes::gettimeofday] if not defined;
                    always update $last_content_t = [Time::HiRes::gettimeofday] upon printing any delta.
                After loop, before handling tool calls etc.:
                   my $prompt_secs;   # unknown without separate metric
                   my $gen_secs;
                   if (defined $first_t && defined $last_content_t) {
                        $gen_secs = Time::HiRes::tv_interval($first_t, $last_content_t);
                   }
        3. Attempt to get usage:
                - Non-stream: already have from JSON decode; just print.
                - Stream:
                    a. While parsing events, look for any JSON that has top-level key "usage" (if present store in `$final_usage`); note such event might come before [DONE] or after? We'll check if exists and not empty then remember it.
                       However once we see `[DONE]` string we break out of loop; so usage must appear prior to that line.
                    b. If found, extract completion_tokens etc from `$final_usage`.
           4. Else fallback: estimate generated tokens by splitting the final assistant response ($resp) on non-whitespace? Actually that's words not tokens. We can do:
                         my $est_output_tokens = length($resp) / 4;   # rough avg 4 bytes per token for English
                  but better is to use same tokenizer as model if we had it loaded (we don't).
              Alternatively, ignore exact count and only show timing metrics: TTFT and TPOT based on chunks? We still need tokens for TPOT.

        Since accurate token count in streaming without server cooperation seems infeasible with current design,
                let's plan to:
                   - If we got usage from event (option 3 above) -> use it.
                   - Else if user really needs exact counts they should disable streaming (AI_STREAM=0).
                   OR  
                   We add a note in help that for token statistics, disable streaming.

        Given the TODO is about adding T/S and other stats FROM THE LLAMA.CPP API,
                we will assume that either:
                    * The llama.cpp instance provides usage per chunk via a non-standard extension (check server logs) OR  
                      We are targeting a specific build/version of llama.cpp which does return `usage` in the final SSE chunk before [DONE] and thus implement parsing for it.

  Let's search quickly in code if there is any handling for usage already? None seen besides non-stream branch.
</think>
