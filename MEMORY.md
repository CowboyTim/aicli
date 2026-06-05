# MEMORY: AI-CLI Project Context

## Summary of Work Done (Session)
- Created/updated **AGENTS.md** with a comprehensive project analysis:
  - Overview, core components, features, current development focus (from TODO), completed items.
- Updated **TODO.md**:
  - Added completed item `- [x] Project analyzed and documentation added to AGENTS.md` under Completed Items.

## Key Points for Future Work
- The project is a Perl‑based AI chat CLI with multi‑provider support, tool system (bash, perl, read/write/grep), session persistence, and Docker support.
- Active development priorities (from TODO):
  - **High Priority**: Streaming improvements (token stats, TTFT/TPOT, thinking tags, markdown rendering), error handling/resilience, tool system upgrades (sandboxing, new tools), configuration management.
  - Medium/Low: Session enhancements, Git integration, UI improvements, testing, multi‑modal, agent collaboration, performance.

## Files of Interest
- `ai.pl` – main script (chat loop, API handling, tool execution).
- `aicli.sh` – Docker wrapper script.
- `Dockerfile` – Alpine‑based build.
- `TODO.md` – roadmap (now includes the analysis completion marker).
- `AGENTS.md` – this analysis file.
- `ai/` – prompt templates.
- `t/` – test directory.

## Next Steps / Suggested Contributions
- Look at High Priority items in TODO.md for immediate tasks.
- Consider implementing streaming token statistics or enhancing thinking‑tag handling.
- Review tool system for adding new tools (e.g., web search, file edit) or sandboxing bash.
- Check configuration management for adding JSON/YAML support.

---
*Memory saved on 2025-09-16*