# llm-gate

A GitHub Action that fails a pull request when any of its commits carry LLM or
AI-assistant attribution, so the author has to strip it before the branch merges.

Attribution trailers are hard to undo once they reach a default branch. GitHub
reads co-author trailers to build a repository's contributor list, a squash merge
copies the trailers from every commit on the branch into the merge commit, and
removing them afterwards means rewriting published history. llm-gate stops them
at review time instead.

## What it flags

| Rule | Examples |
|---|---|
| **AI co-author trailer**: any `*-by:` trailer (`Co-authored-by`, `Signed-off-by`, ...) whose value is an AI identity | Claude, GitHub Copilot, Cursor Agent, Aider, Amp, Crush, Warp, Devin, Jules, Gemini, ChatGPT/Codex, and their `[bot]` accounts and noreply addresses |
| **AI tool trailer**: `Assisted-by:`, `Generated-by:`, `Generated-with:` naming an AI tool or model | the Linux kernel style `Assisted-by: <agent>:<model>` |
| **AI trailer**: trailer keys only AI tooling writes | `AI-Assisted:`, `Amp-Thread-ID:`, `<tool>-Session:` |
| **AI attribution line**: a line that opens with "Generated with/by", "Co-written with", "Created with the help of", "This PR was generated with" (and similar) followed by an AI tool | the 🤖 *Generated with …* footer Claude Code appends, Crush's 💘 footer |
| **AI session link**: links to a chat, session, thread, or agent task | Claude Code sessions, ChatGPT shares and Codex tasks, Amp threads, Devin sessions, Jules tasks |
| **AI author / committer**: the commit itself was authored or committed by an AI bot | `copilot-swe-agent[bot]`, `devin-ai-integration[bot]`, `google-labs-jules[bot]` |

Names are matched as whole identities, so a person who happens to share a
product's name still passes: a co-author "Claude Monet" or "Devin Lee" is fine,
while "Claude Opus 4.5" or "Devin AI" is not. Lines like `Fix cursor position` or
`Add an OpenAI client` are ordinary commit messages and pass too. The pull
request title and description are checked as well, because a squash merge can
use them as the commit message.

## Usage

```yaml
# .github/workflows/llm-gate.yml
name: llm-gate
on:
  pull_request:
    types: [opened, synchronize, reopened, edited] # edited: re-check title/description changes
  merge_group:

permissions:
  contents: read

jobs:
  llm-gate:
    runs-on: ubuntu-latest
    steps:
      - uses: cy-pca/llm-gate@v1
```

No checkout step is needed: the action fetches only the commit objects it needs
(a treeless partial fetch), which takes seconds even on large repositories. If
the job already has a full checkout (`fetch-depth: 0`), it uses that instead.

It runs on any runner with `bash` and `git`, including self-hosted ones
(`runs-on: [self-hosted, Linux, X64]`). On `push` events it checks the pushed
commits; for a new branch, the commits that are not on the default branch.

To block merging, make the `llm-gate` check required in a branch ruleset or
branch protection rule for the default branch.

### Inputs

| Input | Default | |
|---|---|---|
| `check-identities` | `true` | Also fail when a commit's author or committer is an AI bot. Set to `false` if you accept PRs from coding agents and only care about trailers and footers. |
| `check-pr-text` | `true` | Also check the pull request title and description. |
| `extra-patterns` | | Extra case-insensitive ERE patterns, one per line. A commit message line that matches fails the check. |
| `ignore-patterns` | | Case-insensitive ERE patterns, one per line. A line or author identity that matches is never flagged. Use this for a human co-author the identity rules mistake for a bot, such as someone recorded only by a first name that is also a product name. |
| `base`, `head` | from the event | The commit range to check (`base..head`). Set these for `workflow_dispatch` or other events. |
| `token` | `github.token` | Used to fetch commits; needs `contents: read`. |

Output `result` is `pass` or `fail`.

```yaml
      - uses: cy-pca/llm-gate@v1
        with:
          check-identities: false
          ignore-patterns: |
            ^Co-authored-by: Kiro <kiro@example\.jp>$
          extra-patterns: |
            ^X-Internal-Bot:
```

## Fixing a failed check

The job log and summary list each offending commit and line.

* **One commit:** `git commit --amend` (or `git rebase -i` and `reword`), delete
  the lines, then `git push --force-with-lease`.
* **Every commit on the branch:** with [`llm-gate.sh`](llm-gate.sh) on your
  `PATH`, rewrite each message through its `--filter` mode, which drops exactly
  the lines the check flags:

  ```bash
  git rebase -x 'git log -1 --format=%B | llm-gate.sh --filter | git commit --amend --no-verify -F -' origin/main
  ```

  Then `git push --force-with-lease`.
* **AI author or committer:** amend with `--reset-author` (in the `rebase -x`
  command as well) so the commit carries your identity.
* **Pull request title or description:** edit it on GitHub. With the `edited`
  trigger above the check re-runs on its own.

## Local use

`llm-gate.sh` is a standalone script (bash 3.2+ and git):

```bash
llm-gate.sh origin/main..HEAD                   # check a range of commits
llm-gate.sh --message-file .git/COMMIT_EDITMSG  # check one message
git log -1 --format=%B | llm-gate.sh --filter   # print a message without flagged lines
llm-gate.sh --help
```

Exit status is 0 when clean, 1 when attribution is found, and 2 on a usage or
git error.

To catch attribution before it is ever committed, call it from a `commit-msg`
hook (`.git/hooks/commit-msg`, made executable):

```bash
#!/usr/bin/env bash
exec llm-gate.sh --message-file "$1"
```

Or have the hook remove the lines silently instead of refusing the commit:

```bash
#!/usr/bin/env bash
llm-gate.sh --filter <"$1" >"$1.tmp" && mv "$1.tmp" "$1"
```

## Versions

Pin `cy-pca/llm-gate@v1` to follow compatible updates (the `v1` tag moves), or a
full tag such as `@v1.0.0` or a commit SHA to stay fixed. Pattern additions ship
as minor releases, since they can flag messages that passed before.

## Development

```bash
bash tests/run.sh                          # unit and end-to-end tests
shellcheck llm-gate.sh ci.sh tests/run.sh
```

The tests build their fixture commits in throwaway repositories under a temp
directory, and the end-to-end tests serve them over `file://`. No commit carrying
attribution is ever pushed, including from this repository's CI, which also runs
the action against its own pull requests.

## License

[MIT](LICENSE)
