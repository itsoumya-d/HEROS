# Universal Operating System

This project inherits the global Codex Universal Operating System. Use the following workflow as the default for every request, feature, build, run, test, review, and release task in this repository.

You must use the following workflow for EVERY request without exception.

STAGE 1 - UNDERSTAND-ANYTHING
Before producing any output:
- Fully understand the request.
- Determine the real objective.
- Identify assumptions, constraints, dependencies, risks, missing information, and success criteria.
- Expand vague requests into clear intentions.
- Never proceed with an incomplete understanding.

STAGE 2 - GRAPHIFY
Create an internal knowledge graph of the problem.
- Identify all entities, concepts, resources, goals, tasks, people, tools, systems, and relationships.
- Map dependencies and interactions.
- Use the graph as the primary reasoning structure for all subsequent thinking.

STAGE 3 - OBSIDIAN
Retrieve and connect all available knowledge.
- Search existing notes, memories, documentation, previous conversations, references, and related context.
- Connect current work to prior knowledge.
- Reuse existing information whenever possible.
- Continuously enrich the knowledge base with important findings.

STAGE 4 - HEADROOM
Perform deep reasoning before acting.
- Explore multiple approaches.
- Evaluate tradeoffs.
- Check for mistakes, blind spots, inconsistencies, risks, and edge cases.
- Optimize for accuracy, quality, efficiency, scalability, maintainability, and long-term value.
- Self-review before producing results.

STAGE 5 - EXECUTION
Only after completing the previous stages:
- Generate the response, plan, code, design, analysis, decision, recommendation, or action requested.
- Ensure the output reflects insights gathered from all previous stages.

GLOBAL RULES
- The workflow is mandatory for every request.
- No stage may be skipped.
- Apply the workflow regardless of task size or complexity.
- Think before acting.
- Retrieve context before reasoning.
- Reason before executing.
- Verify before finalizing.
- Prioritize correctness over speed.
- Prioritize completeness over assumptions.
- Continuously improve understanding throughout the interaction.

Required sequence:
UNDERSTAND-ANYTHING -> GRAPHIFY -> OBSIDIAN -> HEADROOM -> EXECUTION

This sequence is the default operating system and must run for every interaction.

## Project Start Protocol

For every project, before building, running, or making feature changes:

1. Discover the project shape first: read the nearest AGENTS.md files, README/setup docs, package manifests, lockfiles, build scripts, CI workflows, and relevant status notes.
2. Identify the minimum required toolchain and dependencies for the requested task. Prefer the repository's locked and documented path over broad or speculative installs.
3. Install only what is necessary and missing before build/test/run:
   - JavaScript/TypeScript: prefer npm ci, pnpm install --frozen-lockfile, yarn install --frozen-lockfile, or bun install --frozen-lockfile according to the detected lockfile/package manager.
   - Python: prefer the repository's uv/pip/poetry/pipenv instructions and existing lockfile.
   - Ruby/iOS: prefer bundle install and pod install only when Gemfile/Podfile context requires it.
   - Flutter/Dart: prefer flutter pub get before build/analyze/test when pubspec files are present.
   - Native/mobile builds: install platform dependencies only when the repo or build error proves they are required.
4. If installing requires network access, credentials, package-manager writes outside the workspace, or elevated permissions, ask for approval through the available permission flow and explain why it is needed.
5. Build or verify in the most efficient correct order: focused checks first for narrow changes, broader build/test gates when touching shared code, release paths, dependency contracts, or user-facing workflows.
6. Do not reinstall dependencies blindly if the existing install is current and sufficient. Reuse local caches and previous setup when that is the optimal path.
7. Do not claim the whole project is built, runnable, release-ready, or complete unless the relevant build/test/run/release proof actually succeeded. Report exact blockers and next steps when external setup, credentials, consoles, or unhealthy local services prevent completion.
