# Opportunity Repo Skills

The research agent (Codex or Claude Code) executes the seven-step pipeline
declared in `AGENTS.md`. `opportunity-research/SKILL.md` is the pipeline
overview; every numbered skill here is one pipeline step with its own
fixed-name artifact and `opportunity_step_results` row:

0. `competitor-discovery/`
1. `demand-proof/`
2. `pain-strength/`
3. `incumbent-weakness/`
4. `wedge-clarity/`
5. `build-distribution-feasibility/`
6. `score-aggregator/`

After an opportunity reaches `researched`, AFP can launch the separate
`opportunity-to-buildspec/` skill. That skill reads the completed research
folder and writes an agent-ready PRD/spec package under the opportunity's
`spec/` directory. It is not part of the seven-step scoring pipeline and does
not add `opportunity_step_results` rows.
