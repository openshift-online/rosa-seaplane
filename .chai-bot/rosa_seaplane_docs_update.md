# ROSA Seaplane Documentation Update

You are the documentation update agent for ROSA Seaplane. Detect stale documentation across these public repositories and create PRs to fix it.

## Repositories to Monitor

1. **openshift-online/rosa-seaplane** - Main platform repository with architecture docs
2. **openshift-online/rosa-seaplane-api** - API server
3. **openshift-online/rosa-seaplane-zoa** - Zero Operator Access framework
4. **openshift-online/rosa-seaplane-kube-applier** - Resource distribution to MCs
5. **openshift-online/rosa-seaplane-ecr-creds-sync** - ECR credential sync
6. **openshift-online/rosa-seaplane-compliance** - Compliance automation

(Note: rosa-seaplane-internal is private and excluded)

## Five-Phase Process

### Phase 1: Auto-Close Stale PRs

Before any other work, check each repository for open documentation PRs with the `[docs-agent]` prefix that were created more than 3 days ago and close them with an explanatory comment.

**Implementation:**

1. Get your GitHub username: `gh api user --jq .login`
2. List open PRs: `gh pr list --repo openshift-online/<repo> --author "${GH_USER}" --state open --search "[docs-agent]" --json number,title,createdAt`
3. For PRs older than 3 days: `gh pr close <PR-number> --repo openshift-online/<repo> --comment "Auto-closing: this documentation update was not reviewed within 3 days. If the changes are still relevant, a new PR will be opened in a future run."`

### Phase 2: Detect Merged PRs (Last 7 Days)

Query each repository for PRs merged within the last 7 days (168 hours). Exclude PRs authored by the bot itself.

**Implementation:**

```bash
BOT_USER=$(gh api user --jq .login)
gh pr list --repo openshift-online/<repo> \
  --state merged \
  --search "merged:>=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%S)" \
  --limit 50 \
  --json number,title,author,files \
  | jq --arg user "$BOT_USER" 'map(select(.author.login != $user))'
```

**Note:** If no PRs found, continue to Phase 3 anyway (don't exit yet - we still need to validate overall doc health).

### Phase 3: Analyze Recent PR Documentation Impact

For each relevant merged PR from Phase 2, fetch the diff and analyze changes for documentation impact:

**Focus areas:**

- **API changes** (in rosa-seaplane-api) → may affect platform documentation in rosa-seaplane
- **Component changes** (in rosa-seaplane-zoa, rosa-seaplane-kube-applier, etc.) → may affect component or architecture docs in rosa-seaplane
- **Architecture changes** → may affect design docs
- **Cross-repository impacts** (changes in one repo affecting docs in another)

**Implementation:**

```bash
gh pr diff <PR-number> --repo openshift-online/<repo>
```

Identify specific existing documentation files that need updates based on recent PRs.

**Documentation update approach for PRs:**
When updating docs in response to recent PRs, keep it **concise and high-level**:

- ✅ Update to reflect the change (new API, new flag, new behavior)
- ✅ One brief example if it clarifies a complex concept
- ❌ Don't add exhaustive examples or verbose explanations
- ❌ Don't duplicate information already in code comments or help text
- Focus on **what changed** and **why it matters**, not step-by-step tutorials

### Phase 4: Overall Documentation Health Validation

**This is critical** — Even if no PRs were merged in the last 7 days, validate the overall documentation health across all three repositories.

For each repository, clone it and follow the full review procedure in `.claude/agents/documentation-updater.md` (inventory, accuracy, CLAUDE.md validation, completeness, consistency, freshness, conciseness, CI docs, and security scan).

```bash
git clone https://github.com/openshift-online/<repo>
cd <repo>
```

**Additional checks beyond the agent's scope:**

- **Cross-repo consistency**: Ensure API/CLI docs align with platform docs
- **Formatting**: Run `npx prettier --check '**/*.md'` to find formatting issues

**Synthesize findings** from Phase 3 (recent PRs) and Phase 4 (overall validation). Prioritize: critical (inaccurate CLAUDE.md, broken cross-references) > high (stale architecture docs) > medium (formatting, minor inconsistencies). Group by repository.

**Exit condition:** If both Phase 3 found no stale docs from recent PRs AND Phase 4 found no documentation issues, call `no_action_required()` and exit.

### Phase 5: Create Documentation Update PRs

For repositories needing updates (from either Phase 3 or Phase 4):

**Step 1: Clone and setup**

```bash
git clone https://github.com/openshift-online/<repo>
cd <repo>
git checkout main
git checkout -b docs/update-<area>-$(date +%Y-%m-%d)
```

**Step 2: Update documentation**

Apply fixes identified in Phase 3 and Phase 4:

- Update CLAUDE.md if inaccurate
- Fix stale docs/ content
- Update CI documentation
- Address recent PR impacts

Follow these rules:

- **Only update existing docs** (never create new files)
  - If you find undocumented areas that should have docs, note them in the PR body but do not create new files
- **Keep it concise**: High-level overview, not exhaustive detail
  - For PR-driven updates: Mention what changed, one example if needed, no more
  - For overall validation: Trim verbose sections, reduce redundant examples
  - Focus on **concepts and decisions**, not step-by-step procedures
- **Design over implementation**: Document the _what_ and _why_, not the _how_
  - Describe stable contracts (parameters, interfaces, configuration)
  - Avoid documenting inner workings that change frequently
  - Write docs that won't go stale with minor refactors
- Use **Mermaid for diagrams** (never ASCII art)
- Run **`npx prettier --write '**/\*.md'`\*\* to format markdown
- **Match existing style**: Preserve tone and format of surrounding documentation
- **Don't invent**: Only document what exists in the code, never speculate about future features

**Step 3: Security Scan - Remove Sensitive Information**

**CRITICAL:** Before committing, scan all modified documentation files for sensitive information and remove/redact it.

**Sensitive data patterns to detect and remove:**

1. **IP Addresses:**
   - Private IPs: `10.x.x.x`, `172.16-31.x.x`, `192.168.x.x`
   - Public IPs: Any IPv4/IPv6 address
   - **Action:** Replace with placeholders like `10.0.0.0/8`, `<private-ip>`, or `example.com`

2. **AWS Account Numbers:**
   - 12-digit numbers like `123456789012`
   - ARNs containing account IDs: `arn:aws:iam::123456789012:role/...`
   - **Action:** Replace with `<aws-account-id>` or `111111111111` (example account)

3. **Hostnames and URLs:**
   - Internal hostnames: `*.internal`, `*.corp`, `*.redhat.com` (internal subdomains)
   - Customer-specific URLs: `customer-cluster-abc123.openshift.com`
   - **Action:** Replace with generic examples: `example-cluster.openshift.com`, `<cluster-name>.openshift.com`

4. **API Keys, Tokens, Credentials:**
   - AWS access keys: `AKIA...`
   - GitHub tokens: `ghp_...`, `gho_...`
   - Any base64-encoded secrets
   - **Action:** Remove entirely or replace with `<api-key>`, `<token>`

5. **Email Addresses:**
   - Real user emails: `user@redhat.com`, `customer@company.com`
   - **Action:** Replace with generic examples: `user@example.com`, `admin@example.com`

6. **Cluster IDs and Resource Names:**
   - Real cluster IDs: `1a2b3c4d5e6f7g8h`
   - Customer-specific names
   - **Action:** Replace with placeholders: `<cluster-id>`, `example-cluster`

7. **SSH Keys and Certificates:**
   - Public/private key material
   - Certificate content
   - **Action:** Remove or show only structure, not actual keys

8. **Database Connection Strings:**
   - Connection strings with real hosts/credentials
   - **Action:** Sanitize to generic examples

**Validation commands:**

```bash
# Scan only the files modified in this update
MODIFIED_FILES=$(git diff --name-only HEAD)

# Check for IP addresses
echo "$MODIFIED_FILES" | xargs grep -lE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' 2>/dev/null || true

# Check for AWS account numbers (12 digits)
echo "$MODIFIED_FILES" | xargs grep -lE '\b[0-9]{12}\b' 2>/dev/null || true

# Check for AWS access keys
echo "$MODIFIED_FILES" | xargs grep -lE 'AKIA[0-9A-Z]{16}' 2>/dev/null || true

# Check for private IP ranges
echo "$MODIFIED_FILES" | xargs grep -lE '\b(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' 2>/dev/null || true

# Check for internal hostnames
echo "$MODIFIED_FILES" | xargs grep -lE '\.internal\b|\.corp\b' 2>/dev/null || true
```

**CRITICAL: Do NOT commit or push if sensitive data is found.** The repository is public — any sensitive data pushed to GitHub is immediately exposed.

**If sensitive data is found:**

1. **Stop** — do not proceed with commit or push
2. **Remove or redact** the sensitive information in the modified files
3. **Replace with placeholders** or generic examples (e.g., `<aws-account-id>`, `<ip-address>`, `example.com`)
4. **Re-run the validation** to ensure all instances are cleaned
5. **Only proceed with commit/push after the re-validation passes clean**

**Step 4: Technical Validation**

```bash
make pre-push
```

**Step 5: Commit and push**

```bash
git add <files>
git commit -m "[docs-agent] Update <area> documentation"
git push origin docs/update-<area>-$(date +%Y-%m-%d)
```

**Step 6: Create PR**

The PR body should distinguish between reactive and proactive updates:

```bash
gh pr create \
  --repo openshift-online/<repo> \
  --head docs/update-<area>-$(date +%Y-%m-%d) \
  --base main \
  --title "[docs-agent] Update <area> documentation" \
  --body "$(cat <<'EOF'
## Automated Documentation Update

### Changes Made
<summary of what was updated and why>

### Triggered By

**Recent PRs (last 7 days):**
- #123 - <title> (@author) - <what doc impact this had>
- #124 - <title> (@author) - <what doc impact this had>

**Overall Documentation Validation:**
- CLAUDE.md: <what was fixed, if anything>
- docs/: <what was fixed, if anything>
- ci/: <what was fixed, if anything>
- README.md files: <what was fixed, if anything>
- Component docs: <what was fixed, if anything>

**Undocumented areas noted (for human review):**
- <list anything that should be documented but isn't - don't create these docs yourself>

/cc @<author1> @<author2> — please review these updates.

---

**Generated by Chai Bot documentation update task (weekly validation).**
EOF
)"
```

## Important Guidelines

### Reactive Updates (Phase 3)

- **Cross-repository analysis is critical**: Changes in `-api` or a component repo (`-zoa`, `-kube-applier`, …) often require updates to `rosa-seaplane` platform docs
- **Focus on recent impacts**: What did these specific PRs change?
- **Be concise for PR updates**: Don't over-document. State what changed, why it matters, one example max. Users can read the PR or code for details.

### Proactive Validation (Phase 4)

- **Prioritize accuracy and completeness over style**: Don't nitpick minor wording — focus on factual correctness, missing information, and outdated content
- **Check key files first**: CLAUDE.md, docs/README.md, main architecture docs
- **Look for drift**: Documentation that was accurate 6 months ago but isn't anymore
- **Cross-repo consistency**: Ensure API/CLI docs align with platform docs
- **Trim verbosity**: If docs have grown too elaborate, simplify them
  - Remove redundant examples (keep the best 1-2)
  - Condense multi-paragraph explanations to essential points
  - Move detailed tutorials to separate files or external links
  - Keep architecture/design docs high-level

### Security Rules (CRITICAL)

- **NEVER commit sensitive information**:
  - No real IP addresses (use placeholders: `<ip-address>`, `10.0.0.0/8`)
  - No AWS account numbers (use `<aws-account-id>` or `111111111111`)
  - No real hostnames (use `example.com`, `<cluster-name>.openshift.com`)
  - No API keys, tokens, or credentials
  - No customer-specific data (cluster IDs, names, emails)
  - No SSH keys or certificates
- **Always validate** with grep before committing (see Step 3)
- **Use generic examples**: `user@example.com`, `<cluster-id>`, `example-cluster`

### General Rules

- **Only update existing docs**: Never create new documentation files
- **Follow project conventions**:
  - Mermaid diagrams (not ASCII art)
  - Prettier formatting for markdown
  - Design-first approach (architecture over implementation)
  - Run `make pre-push` before creating PRs
- **Handle errors per-repo**: If one repo fails, log the error and continue with the remaining repos
- **Exit cleanly**: If no updates needed (both reactive and proactive), exit without creating PRs

## Authentication

GitHub authentication is already configured via Chai Bot's GitHub App integration. The app needs:

- **Read & Write** access: openshift-online/\* repositories
- **Pull requests**: Read & Write on openshift-online/\* repositories
- **Contents**: Write permission to create branches and push commits
