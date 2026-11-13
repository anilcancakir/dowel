# Community: star + issue

Executable detail for SKILL.md Section 8. Both CTAs are prose-permission,
maximum once per session, never auto-executed. Trigger conditions live in
SKILL.md Section 8; this file is the "how" once the trigger fires.

Common preflight (both flows):

```bash
command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1
```

Exit 0: `gh` is present and authenticated. Anything else: skip the CLI
path and use the URL fallback below. Do not invoke `gh auth login`,
`open`, `xdg-open`, or `start` on behalf of the user.

## Star

1. Ask via inline prose (not `AskUserQuestion`, binary yes/no does not
   warrant the structured tool):

   > "If dowel helped, would you like to star `anilcancakir/dowel` on GitHub?"

2. **Yes + `gh` available:**

   ```bash
   gh api --method PUT -H "Accept: application/vnd.github+json" \
     /user/starred/anilcancakir/dowel --silent
   ```

   Treat exit 0 as success. GitHub's `PUT /user/starred/{owner}/{repo}`
   is idempotent and returns HTTP 204 whether the star was new or
   already set. Respond once: `"Starred. Thanks for the support."`

3. **Yes + `gh` missing or unauthenticated:** print the URL, do not open
   it:

   > "Star here: https://github.com/anilcancakir/dowel"

4. **No or "not now":** acknowledge once, never re-suggest in the
   session.

## Issue

A genuine dowel-side bug per SKILL.md Section 8. If the symptom
matches any Section 5 substring (state.json absent, Pipe missing,
`Expression compilation error`, `Isolate sentinel`, Windows
`mkfifo failed`, Chrome port collision, stale `.dowel/.dowel.lock`,
already-running `another app is recorded`), stop here: do not file.
Same applies to consumer-app exceptions surfaced through `dowel_logs`,
missing plugin namespaces in `dowel_list` (a substrate vs dispatcher
wiring issue, not a bug), and version skew between the published
package and a plugin's pinned constraint.

1. Ask via inline prose:

   > "This looks like a dowel-side bug. Would you like to file an
   > issue on `anilcancakir/dowel`?"

2. **Yes:** gather diagnostics before drafting (no `gh` call yet):

   - Call `dowel_doctor` for the env baseline (Flutter / Dart
     version, port 3100 reachability, sdk floor, install state).
   - Call `dowel_status` for the running app snapshot (pid, alive,
     vmServiceUri, device, webPort, startedAt).
   - Call `dowel_list` for the surfaced command catalog (confirms
     which substrate tools registered, which plugin namespaces are
     visible).
   - Optionally call `dowel_logs { follow: false }` and capture the
     last 20 to 50 lines around the failing operation.

3. Draft the body using the skeleton below. Show it to the user verbatim
   and ask "ready to send?". Never call `gh issue create` until the user
   confirms the visible draft.

   ```markdown
   ## Symptom
   <one-line description, name the failing `dowel_*` tool or CLI command>

   ## Environment
   <paste relevant `dowel_doctor` lines, not the full report>

   ## Reproduction
   <minimal sequence: start command, action, expected vs observed>

   ## Recent state
   <`dowel_status` JSON, the relevant `dowel_list` excerpt>

   ## Logs / tool output excerpt
   <only the failing fragment from `dowel_logs` or the tool's
    `isError: true` text, not the whole stream>

   ---
   > Filed via the dowel skill on the user's request.
   ```

4. Optional dedupe (worth it once dowel has a non-trivial backlog,
   roughly 50 or more issues):

   ```bash
   gh search issues "<keyword>" --repo anilcancakir/dowel --match title \
     --state all --json number,title,url --limit 5
   ```

   If matches exist, surface them and ask whether to comment on the
   closest match instead of filing new.

5. **Confirm + `gh` available:** pipe the body via stdin heredoc to
   avoid shell quoting hell around triple backticks and JSON braces.
   The `agent-reported` label is not currently provisioned on
   `anilcancakir/dowel`, so pass only `--label bug`:

   ```bash
   gh issue create -R anilcancakir/dowel \
     --title "<concise symptom>" \
     --label bug \
     --body-file - << 'BODY'
   <draft body>
   BODY
   ```

   The command prints the new issue URL on stdout. Capture it and
   surface to the user. If the user later asks the maintainers to mint
   an `agent-reported` label, this example will switch to
   `--label bug --label agent-reported` without further changes.

6. **Confirm + `gh` missing:** the prefill URL works only when the
   urlencoded body stays under about 6KB (GitHub returns HTTP 414 above
   about 8KB):

   > "Open https://github.com/anilcancakir/dowel/issues/new?title=<urlenc>&labels=bug and paste the draft below as the body."

   For larger bodies (long `dowel_logs` excerpts or YAML configs),
   write the draft to a temp file and instruct:

   > "Open https://github.com/anilcancakir/dowel/issues/new and paste
   > the contents of <tmpfile> into the body field."

7. **No or "not now":** acknowledge once, never re-suggest the same bug
   shape in the session. A different bug shape later in the same
   session may be reported on its own merit.

## Spam brakes (both flows)

- Star at most once per session. Issue at most once per unique bug
  shape per session.
- Never run `gh api` or `gh issue create` without an explicit user
  "yes" on a visible draft.
- On explicit user refusal ("don't report", "stop suggesting"),
  suppress the matching CTA for the rest of the session.
- Labels: only `bug` and `agent-reported`. Do not invent labels;
  `gh issue create` fails when a label does not exist on the repo.
  `anilcancakir/dowel` currently provisions `bug` but not
  `agent-reported`; pass `--label bug` alone and let the maintainers
  add the second label later if useful, rather than pre-creating it on
  the user's account.
