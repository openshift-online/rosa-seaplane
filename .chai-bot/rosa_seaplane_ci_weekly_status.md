# Scheduled report: ROSA Seaplane CI weekly status

You are running a **cron** scheduled task that produces a weekly status update for the ROSA Seaplane team. **Always produce a report.** **Never** call `no_action_required()`.

## Goal

Provide a concise weekly snapshot of Jira epic progress and PR activity across ROSA Seaplane repositories.

## Procedure

### 1. Query Jira initiative and epic progress

Query the child initiatives and epics under these three parent Outcomes that have **component = "ROSA Seaplane"** and **team = "[ROSA] Seaplane"**:

- [HPSTRAT-62](https://redhat.atlassian.net/browse/HPSTRAT-62): Red Hat Cloud Data Sovereignty
- [HPSTRAT-10](https://redhat.atlassian.net/browse/HPSTRAT-10): ROSA - Zero Operator Access
- [HPSTRAT-11](https://redhat.atlassian.net/browse/HPSTRAT-11): FedRAMP Moderate Technical Delivery

For each matching initiative/epic, collect: status (To Do / In Progress / Done), and for In Progress items count child stories closed vs total.

Group epics by status — **In Progress** first (with progress badge), then **To Do**, then **Done** (status category = Done or Closed). Omit any section that has no epics.

For In Progress epics, append completion as `— X% done`. Right-align the percentage text across all In Progress epics so the `%` signs line up.

### 2. Find key PRs from the past week

Search for recently opened or merged PRs from ALL contributors (not just one person) across these repos:

- `openshift-online/rosa-seaplane` (main codebase)
- `openshift-online/rosa-seaplane-api` (API repository)
- `openshift-online/rosa-seaplane-zoa` (Zero Operator Access framework)
- `openshift-online/rosa-seaplane-kube-applier` (resource distribution to MCs)
- `openshift-online/rosa-seaplane-ecr-creds-sync` (ECR credential sync)
- `openshift-online/rosa-seaplane-compliance` (compliance automation)

Use GitHub tools or `fetch_web_content` to find PRs from the last 7 days. Include merged and notable open PRs.

### 3. Channel response

Post the report as a single Slack message. Keep it scannable — no trend tables, no verbose formatting.

```text
:fyi: *CI Weekly — %DATE%*

*Epics:*
*In Progress:*
<%URL%|%EPIC_KEY%>: %SUMMARY% — %X%% done
...
*To Do:*
<%URL%|%EPIC_KEY%>: %SUMMARY%
...
*Done:*
<%URL%|%EPIC_KEY%>: %SUMMARY%
...

*PRs (7d):*
<https://github.com/openshift-online/rosa-seaplane/pulls|rosa-seaplane>: %MERGED% merged, %OPEN% open
<https://github.com/openshift-online/rosa-seaplane-api/pulls|rosa-seaplane-api>: %MERGED% merged, %OPEN% open
<https://github.com/openshift-online/rosa-seaplane-zoa/pulls|rosa-seaplane-zoa>: %MERGED% merged, %OPEN% open
<https://github.com/openshift-online/rosa-seaplane-kube-applier/pulls|rosa-seaplane-kube-applier>: %MERGED% merged, %OPEN% open
<https://github.com/openshift-online/rosa-seaplane-ecr-creds-sync/pulls|rosa-seaplane-ecr-creds-sync>: %MERGED% merged, %OPEN% open
<https://github.com/openshift-online/rosa-seaplane-compliance/pulls|rosa-seaplane-compliance>: %MERGED% merged, %OPEN% open
```

- Group epics by status: In Progress (with progress badge), To Do, Done
- Omit status sections that have no epics
- Right-align `% done` text across In Progress epics
- Only list repos that had PR activity in the last 7 days

## Constraints

- Always produce a report.
- Verify PR merge status before claiming "merged."
