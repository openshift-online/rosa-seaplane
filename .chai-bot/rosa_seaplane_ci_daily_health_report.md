# Scheduled report: ROSA Seaplane CI daily health report

You are running a **cron** scheduled task that produces a daily CI health report for ROSA Seaplane jobs. Keep the report **as concise as possible** to minimize channel noise. When everything is healthy, keep the summary concise, but still use the standard report structure. Only expand into detail when something needs attention.

## Goal

Check the pass/fail history (last 10 completed builds per job) for ROSA Seaplane CI periodic jobs. Report overall CI health and individual job status.

In addition, report the **OCP nightly e2e periodics** — the HyperShift periodics that run rosa-seaplane e2e against OCP nightly release images. Report them as extra rows in the same trend table plus a condensed status line in the header. If today's run has finished, show its real pass/fail; if it is still running (or hasn't started), show `:loader:` in its today cell instead of a pass/fail.

- Always post the top-level status to the channel (never call `no_action_required()`)
- If all jobs are passing: post the status summary only — no threaded replies
- If any job is failing: post the status summary, then create a threaded reply per failing job with investigation

## Procedure

### 1. Load job configuration

Fetch the CI configuration from the single source of truth:
`https://raw.githubusercontent.com/openshift/release/refs/heads/main/ci-operator/config/openshift-online/rosa-seaplane/openshift-online-rosa-seaplane-main.yaml`

Use `fetch_web_content` to retrieve this YAML file. It defines all tests including periodic jobs with `cron:` schedules.

**Track these 3 periodic jobs:**

- `nightly-ephemeral` (test name `as: nightly-ephemeral`)
- `nightly-integration` (test name `as: nightly-integration`)
- `nightly-stage` (test name `as: nightly-stage`)

The full Prow job names follow the pattern:
`periodic-ci-openshift-online-rosa-seaplane-main-{test-name}`

If the fetch fails, fall back to these job names:

- periodic-ci-openshift-online-rosa-seaplane-main-nightly-ephemeral
- periodic-ci-openshift-online-rosa-seaplane-main-nightly-integration
- periodic-ci-openshift-online-rosa-seaplane-main-nightly-stage

**Also track these 2 OCP nightly e2e periodics** (HyperShift repo — rosa-seaplane e2e against OCP nightly release images, `cron: 0 8 * * *`):

- `periodic-ci-openshift-hypershift-release-5.0-periodics-e2e-rosa-seaplane`
- `periodic-ci-openshift-hypershift-release-5.1-periodics-e2e-rosa-seaplane`

Their config lives in the HyperShift CI config (not the rosa-seaplane config above):

- `https://raw.githubusercontent.com/openshift/release/refs/heads/main/ci-operator/jobs/openshift/hypershift/openshift-hypershift-release-5.0-periodics.yaml`
- `https://raw.githubusercontent.com/openshift/release/refs/heads/main/ci-operator/jobs/openshift/hypershift/openshift-hypershift-release-5.1-periodics.yaml`

For these two jobs, collect their recent completed runs (date, pass/fail, build ID). They render as two extra rows in the shared trend table (`hypershift-ocp-5.0-nightly`, `hypershift-ocp-5.1-nightly`). Today's cell shows a real pass/fail once the run has finished; while it is still running (or hasn't started) it shows `:loader:`. They also appear in a condensed header line (see Step 4).

### 2. Collect build history (last 10 runs)

For each job, collect the **last 10 completed job runs** for the trend table. Use Prow CI tools (`search_prow_jobs`, `query_prowjobs`, etc.) or `fetch_web_content` on the job-history page.

**Same-day reporting rule (rosa-seaplane jobs):** For `ephemeral`, `integration`, and `stage`, the "Latest Run Status" section must report **today's run**. Do not fall back to a previous day's completed run for the latest status. These three jobs run at `0 4 * * *` (04:00 UTC), so by the time this report runs they have normally finished.

**Exception — OCP nightly e2e periodics:** Report these based on whether today's run has finished, not on the clock:

- **If today's run has finished:** use it as a normal pass/fail — real `✅`/`❌` in the today cell, and a `passing (<date>)` / `failing (<date>)` header.
- **If today's run is still running or hasn't started:** show `:loader:`/`⌛` in the today cell and base the header on the latest completed run, e.g. `in progress (last passed Oct 9)`.

This exception **overrides** both the "today only" rule above and the generic "Retry for in-progress jobs" rule below: do **not** wait or retry on an unfinished OCP nightly run — report it as `:loader:`/in progress straight away. This keeps the row correct whether the periodic lands before or after this report, and avoids a confusing "no run today" when it simply hasn't finished.

**Job status values:** Report the actual state of today's run:

- **passing** — today's run completed successfully
- **failing** — today's run completed with failures
- **running** — today's run is currently in progress
- **scheduled** — today's run is queued but not yet started
- **no run today** — no run was triggered today

**Retry for in-progress jobs** (the three rosa-seaplane jobs; the OCP nightly periodics are excepted per Step 2 above)**:** If today's run for any tracked job is in a `scheduled` or `running` state:

1. Wait **10 minutes** and re-check the job status
2. Repeat up to **3 times** (30 minutes maximum wait)
3. After 30 minutes, report the current state as-is (e.g., "running" if still in progress)

**Important:** Track each of the last 10 runs with their dates:

- For each run, record: date, pass/fail status, build ID
- Format date as "MonDD" (e.g., "Jun10", "Jun11", "Jun19")
- Runs are ordered: oldest run first → newest run last (left to right)
- Count total: how many of the 10 runs passed vs failed
- Example: If 7 passed and 3 failed → "7/10 (70%)"

If Prow tools don't return historical build data directly, use `fetch_web_content` to retrieve the job-history page at `https://prow.ci.openshift.org/job-history/gs/test-platform-results/logs/%JOB_NAME%`. The HTML contains `var allBuilds = [{ID, Result, Started, Duration}];`.

### 3. Compute pass rates and health status

**Per-job pass rate**: pass/total for last 10 runs (e.g., 7/10 = 70%).

**10-run trend table**: Create a table with dates as header and jobs as rows:

- **Header row**: Dates in MonDD format (e.g., Jun10, Jun11, Jun12, ...), newest = today in the rightmost column
- **Job rows**: Job name followed by ✅ or ❌ for each run, then the pass count (e.g. `9/10`)
- **OCP nightly rows** go in the same table. Today's cell is a real pass/fail once the run has finished, or `:loader:` while it is still running (see the Step 2 exception); the pass count ignores a `:loader:` cell
- Order: oldest run first (leftmost) → newest run last (rightmost)
- Use monospace formatting for alignment; pad all labels to the longest

**Table format example:**

```text
                            Jun10 Jun11 Jun12 Jun13 Jun14 Jun15 Jun16 Jun17 Jun18 Jun19
ephemeral:                   ✅    ✅    ✅    ✅    ✅    ✅    ✅    ✅    ✅    ✅   10/10
integration:                 ✅    ✅    ❌    ✅    ✅    ✅    ✅    ✅    ❌    ❌    7/10
stage:                       ✅    ✅    ✅    ✅    ✅    ❌    ✅    ✅    ✅    ✅    9/10
hypershift-ocp-5.0-nightly:  ✅    ✅    ✅    ✅    ✅    ✅    ✅    ✅    ✅   :loader:  9/9
hypershift-ocp-5.1-nightly:  ✅    ❌    ✅    ✅    ✅    ✅    ✅    ✅    ✅   :loader:  8/9
```

**Overall CI health** (based on today's run status for each job):

Evaluate status in this order:

- :white_circle: No runs today — no runs were triggered today for any job
- :hourglass_flowing_sand: Pending — one or more jobs are still running or scheduled after retries
- :large_green_circle: All jobs passing (3/3) — all today's runs completed successfully
- :red_circle: All jobs failing (0/3) — all today's runs failed
- :large_yellow_circle: Mixed status — all other combinations, including partial no-run states

**Individual job health** (based on today's run):

- :large_green_circle: Today's run passed
- :red_circle: Today's run failed
- :hourglass_flowing_sand: Today's run is still running or scheduled (after retries exhausted)
- :white_circle: No run triggered today

### 4. Channel response (top-level summary)

Post a concise summary as your channel response. Use concise job names: "ephemeral", "integration", and "stage".

**Emoji key:** :large_green_circle: passing, :red_circle: failing, :large_yellow_circle: mixed, :hourglass_flowing_sand: running/scheduled, :white_circle: no run today. In the trend table, a `:loader:` cell means that OCP nightly run is still running (or hasn't started).

```text
%OVERALL_EMOJI% *CI Daily — %DATE%*
%JOB_EMOJI% ephemeral: %STATUS% (<%URL%|run>)  |  %JOB_EMOJI% integration: %STATUS% (<%URL%|run>)  |  %JOB_EMOJI% stage: %STATUS% (<%URL%|run>)
%JOB_EMOJI% latest OCP nightly: 5.0 %STATUS% (<%URL%|run>)  |  5.1 %STATUS% (<%URL%|run>)

                            Oct01 Oct02 Oct03 Oct04 Oct05 Oct06 Oct07 Oct08 Oct09 Oct10
ephemeral:                   ✅    ✅    ✅    ✅    ✅    ✅    ✅    ✅    ✅    ✅   10/10
integration:                 ✅    ✅    ❌    ✅    ✅    ✅    ✅    ✅    ❌    ❌    7/10
stage:                       ✅    ✅    ✅    ✅    ✅    ❌    ✅    ✅    ✅    ✅    9/10
hypershift-ocp-5.0-nightly:  ✅    ✅    ✅    ✅    ✅    ✅    ✅    ✅    ✅   :loader:  9/9
hypershift-ocp-5.1-nightly:  ✅    ❌    ✅    ✅    ✅    ✅    ✅    ✅    ✅   :loader:  8/9
```

**One merged table; the last column is today.** The rosa-seaplane jobs run at 04:00 UTC and have finished by report time, so their today cell is a real ✅/❌. For the OCP nightly periodics, the today cell is a real ✅/❌ if that run has finished, or `:loader:` while it is still running (or hasn't started). The pass count ignores a `:loader:` cell, so an in-progress day reads e.g. `9/9`.

**Header line:** lead with a single `%JOB_EMOJI%` for the combined OCP nightly status (red if either version failed, green if both are passing/in progress, otherwise the mixed/pending dot — same rules as individual job health). Then, for each version, show the shorthand (`5.0`, `5.1`), the status in plain words, and a link to that version's latest run `(<%URL%|run>)`. Link to the run the status describes (the finished run, or today's in-progress build).

Status is one of:

- `passing (Oct 11)` — today's run finished green
- `failing (Oct 11)` — today's run finished red
- `in progress (last passed Oct 11)` — today's run hasn't finished yet

Write the header status in plain words only — no emoji or glyphs. The `⌛` spinner and `✅`/`❌` marks belong in the trend-table cell, not the header.

**Column alignment:** pad every label to the width of the longest (`hypershift-ocp-5.1-nightly:`) so the date header and all cells line up vertically.

**Rendering note:** Slack renders `:loader:` as the spinner only in normal message text, **not** inside a ` ``` ` code block (there it shows the literal `:loader:`). So post the trend table as a normal monospace-aligned message rather than a fenced code block, or — if you must keep the fence for alignment — fall back to the unicode `⌛` in that cell. ✅/❌ are unicode and render fine either way.

### 5. Failure analysis (threaded replies — only when jobs are failing)

**Skip this step entirely if all jobs are passing.** Only create threaded replies when a job has failed. This includes the two **OCP nightly e2e** periodics — if the latest run of either failed, create a threaded reply for it too.

After your top-level summary (Step 4), emit `---THREAD_DETAILS---` on its own line. Everything after that delimiter becomes threaded replies (not part of the channel summary). Separate each threaded reply with `---THREAD_BREAK---` on its own line.

For each job whose **latest run failed**, produce a **separate threaded reply** with investigation. Follow the investigation procedure in `.claude/agents/ci-troubleshooter.md` to diagnose the failure. The source is `main` — read files directly with the Read tool.

**For every failure, perform ALL THREE analysis steps before classifying. Do not classify as Flake without completing all three.** Unclear is permitted when S3 logs cannot be obtained, but only with a documented error and evidence gap.

1. **Prow artifact analysis** (Step 5 in ci-troubleshooter) — fetch and analyze the build logs and artifacts from GCS. Identify the failing step, error messages, and failure scope.

2. **S3 log extraction and analysis** (Step 5b in ci-troubleshooter) — **MANDATORY.** Always download and extract tar.gz archives to a local workspace directory. Perform broad grep-based analysis across all namespaces, not just the suspected ones. Follow the broad S3 log analysis procedure in the ci-troubleshooter agent.
   - Use the AWS profiles matching the failing job:
     - Ephemeral jobs (`nightly-ephemeral`): `chai-rc-ci` for RC, `chai-mc-ci` for MC
     - Integration jobs (`nightly-integration`): `chai-rc-int` for RC, `chai-mc-int` for MC
     - Stage jobs (`nightly-stage`): `chai-rc-stage` for RC, `chai-mc-stage` for MC
   - Fetch scope based on Prow analysis: RC-only, MC + RC, or both if unclear
   - If S3 logs are inaccessible, report the specific error — classification ceiling becomes Unclear

3. **Git commit correlation** (Step 5c in ci-troubleshooter) — **MANDATORY.** Identify the last passing run, find all commits between last-good and current-bad, and examine commits touching the failing component. Also check `rosa-seaplane-api` for API/seaplane-operator failures.

**S3 log handling:** Always extract tar.gz locally for full analysis. Clean up downloaded files immediately after analysis is complete — never leave S3 logs on disk between runs. See Step 5b in `.claude/agents/ci-troubleshooter.md` for the full procedure.

**Write threaded replies to be read by a human skimming Slack on their phone.** Lead with a plain-English headline, keep sentences short, and use whitespace and bullets so the eye can jump to what matters. Depth lives in the bullets, not in one dense paragraph.

**Slack formatting rules (mrkdwn — not full Markdown):**

- Use `*bold*` for section labels. Slack does **not** render `#` headings or Markdown tables — never use them in a reply.
- Separate sections with a blank line so they don't run together.
- Use `•` bullets for lists. Keep each bullet to one line where possible.
- Put log excerpts, errors, paths, and commit SHAs in `inline code`. Use a fenced block only for a multi-line excerpt that truly needs it.
- Lead with the one-line headline; a reader should understand the failure from the first two lines without scrolling.
- Prefer `·` or `:` as inline separators. Avoid stacking many facts on one line with `|`.

Format each threaded reply like this (omit any section that doesn't apply — e.g. no `Streak` line on a first occurrence):

```text
%STATUS_EMOJI% *%JOB_NAME%* · %CLASS_EMOJI% %CLASSIFICATION% · %PASS%/10 passing

> %ONE_LINE_PLAIN_ENGLISH_HEADLINE — what broke, in human terms%

*What happened*
%2-3 short sentences: the symptom, then the underlying cause.%

*Evidence*
• :mag: *Prow* — %failing step + key error, e.g. `e2e-tests` failed at `TestClusterCreation` timeout after 42m%
• :package: *Cluster logs (S3)* — %key finding, e.g. `kube-applier` pod in CrashLoopBackOff, 47× `ResourceNotFoundException`% (or `:warning: not available — <reason>`)
• :pushpin: *Commits* — %suspect commit `a1b2c3d` + why it's relevant, or `none between last pass and this run`%
• :chart_with_upwards_trend: *Trend* — %e.g. 2nd day in a row, same signature / first occurrence in 10 runs%

*Scope* %RC / MC / RC→MC% · *Failed phase* %phase% (%duration%)

*Fix* %PR link + one-line what it changes / proposed fix awaiting confirmation / where a non-seaplane fix belongs%

:link: <%JOB_RUN_URL%|Build #%NUMBER%> · %DATE%%  · failing since %SINCE_DATE% (%N% days) if streak%
```

Use concise job names: "ephemeral", "integration", "stage", or "ocp-5.x-nightly".

### 5a. Classify failure — genuine first

For each failing job, classify the failure following Step 7 in `.claude/agents/ci-troubleshooter.md`. **The default assumption is Genuine until evidence proves otherwise.** Aim for Genuine classification wherever evidence supports it.

- **🔧 Genuine** (default) — configuration or code issue, fix PR required
- **🔀 Flake** — transient/intermittent, no code fix needed. **Requires strong justification.**
- **⚠️ Unclear** — last resort when evidence is genuinely contradictory or S3 logs could not be obtained

**Evidence requirements:** Every classification MUST cite evidence from all three sources:

1. **Prow artifacts** — what error was found in the build logs
2. **S3 logs** — what the extracted cluster logs show (healthy pods, error patterns, restarts)
3. **Git history** — whether suspect commits exist between last-good and current-bad runs

If any source was not analyzed, the classification must explain why and acknowledge the evidence gap. A classification of Flake without S3 log and git history evidence is not valid. Unclear is permitted when S3 or git evidence could not be obtained, provided the specific access error and resulting evidence gap are documented.

Use the 10-run trend table and consecutive failure streak as additional signal. Two or more consecutive failures with the same error signature is almost certainly genuine. A single isolated failure with S3 logs showing healthy state AND no suspect commits AND a known transient error pattern may be a flake.

### 5b. Consecutive failure analysis

When a job has failed on **2 or more consecutive days**, do not analyze today's failure in isolation:

1. Compare today's failure with the previous day(s) — are the error signatures the same or different?
2. If **same root cause**: note the streak length and reinforce the diagnosis with accumulated evidence.
3. If **root cause shifted**: clearly state the change. This triggers PR lifecycle management (see 5c).

Include the cross-day comparison in the threaded reply so readers understand the trend without checking previous reports.

### 5c. Actions per classification

Follow Step 10 in `.claude/agents/ci-troubleshooter.md` for the full procedure. The action differs by classification:

**Seaplane-repo-only fix constraint (applies to ALL jobs):** Only propose/raise a fix PR when the fix lands in a **seaplane repo** — `rosa-seaplane`, `rosa-seaplane-api`, `rosa-seaplane-zoa`, `rosa-seaplane-kube-applier`, `rosa-seaplane-ecr-creds-sync`, or `rosa-seaplane-compliance`. This matters most for the **OCP nightly e2e** periodics, whose root cause may be in HyperShift or the OCP nightly payload itself. If the fix belongs in a non-seaplane repo (e.g. `openshift/hypershift`, `openshift/release`, or an OCP component), **do not raise a PR**. Instead report the root cause in the threaded reply, state where the fix belongs, and recommend manual follow-up. Still raise a PR normally when the genuine fix is in a seaplane repo.

**🔧 Genuine — raise PR directly (only if the fix is in a seaplane repo, per the constraint above):**

1. **First genuine failure**: share root cause, raise a PR with the fix against the appropriate repo (`rosa-seaplane`, `rosa-seaplane-api`, `rosa-seaplane-zoa`, `rosa-seaplane-kube-applier`, `rosa-seaplane-ecr-creds-sync`, or `rosa-seaplane-compliance`). Branch name: `chai-bot/fix-<job>-<short-description>`. Label: `chai-bot`.
2. **Continued genuine failure (same root cause)**: find the existing open chai-bot PR and add a comment with today's failure URL and any new evidence. Do not create a duplicate PR.
3. **Root cause shifted**: close the existing PR with a comment explaining the root cause change. Open a new PR targeting the updated root cause.

**🔀 Flake — share proposed fix, ask team:**

1. Share the root cause analysis and describe the proposed fix (what file, what change).
2. Ask the team in the thread whether to raise a PR:
   ```
   This appears to be a flake — proposed fix: <summary of change>.
   Should I raise a PR for this? Reply in this thread to confirm.
   ```
3. If the team confirms in the thread, raise the PR. Otherwise skip.
4. If a flake recurs consecutively with the same error, reclassify as Genuine and raise a PR.

**⚠️ Unclear — share analysis, request manual investigation:**

1. Share everything that was checked: Prow artifacts examined, S3 logs fetched (or why they weren't available), error messages found, components inspected.
2. Explain **why** the classification is unclear — e.g., first occurrence with no matching pattern, ambiguous error, insufficient log data.
3. Share the **likely root cause** (best guess) even if confidence is low.
4. Ask the team to investigate manually in the thread:
   ```
   ⚠️ Unable to determine root cause with confidence. Likely cause: <best guess>.
   This needs manual investigation. Please share findings in this thread —
   learnings will be incorporated into future CI analysis.
   ```
5. If the team investigates and shares findings in the thread, offer to turn those learnings into a PR that updates `.claude/agents/ci-troubleshooter.md`. Post a **single** message in the thread — do not repeat the offer or follow up if there's no response:
   ```
   Based on the findings shared here, I can update the CI troubleshooter to recognize this pattern in future runs.
   Should I raise a PR for that? (updates .claude/agents/ci-troubleshooter.md)
   ```
   If approved, raise a PR. If no response or declined, skip — the team can always update the agent manually.
6. If an Unclear failure becomes Genuine after consecutive runs or team input, raise a PR at that point.

Always check for existing chai-bot PRs before creating a new one:

```bash
gh pr list --author @me --label chai-bot --state open --search "<job-name> in:title"
```

Include the PR link, team prompt, or investigation request in the threaded reply as appropriate.

**Example — genuine (PR raised):**

```text
:large_yellow_circle: *CI Daily — Jun 30*
:large_green_circle: ephemeral: passing (<url|run>)  |  :red_circle: integration: failing (<url|run>)  |  :large_green_circle: stage: passing (<url|run>)
:large_green_circle: latest OCP nightly: 5.0 in progress (last passed Jun 29) (<url|run>)  |  5.1 in progress (last passed Jun 29) (<url|run>)

                            Jun21 Jun22 Jun23 Jun24 Jun25 Jun26 Jun27 Jun28 Jun29 Jun30
ephemeral:                   ✅    ✅    ✅    ✅    ✅    ✅    ✅    ✅    ✅    ✅   10/10
integration:                 ✅    ✅    ❌    ✅    ✅    ✅    ✅    ✅    ❌    ❌    7/10
stage:                       ✅    ✅    ✅    ✅    ✅    ❌    ✅    ✅    ✅    ✅    9/10
hypershift-ocp-5.0-nightly:  ✅    ✅    ✅    ✅    ✅    ✅    ✅    ✅    ✅   :loader:  9/9
hypershift-ocp-5.1-nightly:  ✅    ✅    ✅    ✅    ✅    ✅    ✅    ✅    ✅   :loader:  9/9

---THREAD_DETAILS---

:red_circle: *integration* · 🔧 Genuine · 7/10 passing

> Hosted clusters never come up because the MC can't apply resources — kube-applier is crash-looping against a DynamoDB table that doesn't exist.

*What happened*
The `TestClusterCreation` e2e test timed out waiting for the hosted cluster to become ready. On the MC, the kube-applier pod is in CrashLoopBackOff: it's pointed at a DynamoDB table name that was changed in a recent ArgoCD values edit, so every apply fails.

*Evidence*
• :mag: *Prow* — `e2e-tests` failed at `TestClusterCreation` timeout after 42m
• :package: *Cluster logs (S3)* — `kube-applier/.../current.log`: 47× `ResourceNotFoundException: Requested resource not found`; pod in CrashLoopBackOff
• :pushpin: *Commits* — `a1b2c3d` `feat(argocd): update kube-applier DynamoDB config` touches `argocd/config/management-cluster/kube-applier/`
• :chart_with_upwards_trend: *Trend* — 2nd day in a row, identical error signature to Jun 29

*Scope* RC→MC · *Failed phase* e2e-tests (after 42m)

*Fix* <https://github.com/openshift-online/rosa-seaplane/pull/700|#700> — restore the correct table name in kube-applier values (updated today with this run's evidence)

:link: <url|Build #1234> · Jun 30 · failing since Jun 29 (2 days)
```

**Example — flake (ask team):**

```text
:red_circle: *ephemeral* · 🔀 Flake · 9/10 passing

> One-off provision timeout that looks like transient AWS API throttling, not a code problem.

*What happened*
`provision-ephemeral` timed out during Terraform apply waiting on the EKS API. The previous run and all earlier runs passed, and the cluster logs show no unhealthy state, so this reads as a transient hiccup rather than a regression.

*Evidence*
• :mag: *Prow* — `provision-ephemeral` failed with `i/o timeout` during Terraform apply (matches known AWS API throttling)
• :package: *Cluster logs (S3)* — all pods healthy, no CrashLoopBackOff, clean RC state after the timeout
• :pushpin: *Commits* — none between last pass (Jun 29, `f4e5d6c`) and this run touch `terraform/` or `scripts/buildspec/`
• :chart_with_upwards_trend: *Trend* — first failure in 10 runs, no pattern

*Scope* RC · *Failed phase* provision-ephemeral

*Fix* Proposed: add retry-with-backoff to the Terraform apply step in `scripts/buildspec/provision-infra-rc.sh` (not raised — flake needs confirmation)

:link: <url|Build #5678> · Jun 30

This looks like a flake. Proposed fix: add retry-with-backoff to the Terraform apply in `provision-infra-rc.sh`.
Should I raise a PR? Reply in this thread to confirm.
```

**Example — unclear (request manual investigation):**

```text
:red_circle: *integration* · ⚠️ Unclear · 8/10 passing

> platform-api returned a 500 during scaling, but every log looks healthy — evidence points two ways.

*What happened*
`TestClusterScaling` failed on an unexpected 500 from platform-api. The build log has no stack trace, and the cluster logs show the platform-api pod healthy with normal request patterns right up to the failure. Best guess is a race condition that didn't leave a trace, but the evidence isn't conclusive.

*Evidence*
• :mag: *Prow* — `TestClusterScaling` got HTTP 500 from platform-api, no stack trace in the build log
• :package: *Cluster logs (S3)* — broad scan clean: no CrashLoopBackOff, no OOMKilled, no restarts; platform-api logs normal to the failure timestamp
• :pushpin: *Commits* — `b2c3d4e` `refactor(api): restructure scaling handler` touches the scaling path, but the change looks cosmetic (rename only)
• :chart_with_upwards_trend: *Trend* — first occurrence in 10 runs, no matching prior pattern

*Why unclear* Logs show a fully healthy cluster, yet the API returned 500. The one suspect commit is cosmetic. Most likely a transient race not captured in logs, but that can't be confirmed from the evidence.

*Scope* RC · *Failed phase* e2e-tests

:link: <url|Build #9012> · Jun 30

⚠️ Can't pin the root cause with confidence. Likely a race condition in the platform-api scaling handler.
Please share any findings in this thread — if we identify the cause, I can raise a PR to teach the CI troubleshooter this pattern.
```

## Constraints

- Keep the top-level summary under 2000 characters. All detailed analysis goes in threaded replies.
- If more than half the jobs return no data, warn about possible Prow/GCS issues at the top.
