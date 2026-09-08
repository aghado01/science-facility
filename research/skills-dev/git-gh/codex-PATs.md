For an external agent/MCP that can read and act on your Aipithicus repositories, create a **fine-grained PAT**, scoped to the Aipithicus account and only the repositories it actually needs. Fine-grained PATs are GitHub’s recommended PAT type: they can be restricted to one resource owner, selected repositories, and explicit permissions.

## Sensible default token

For an agent that reads code, manages issues/discussions, and opens or updates pull requests:

| Repository permission | Level | Enables |
|---|---:|---|
| **Contents** | Read and write | Read files; create branches/commits and push agent changes |
| **Issues** | Read and write | List, create, comment on, label, assign, close/reopen issues |
| **Pull requests** | Read and write | Read diffs/reviews; open, comment on, update PRs |
| **Discussions** | Read and write | Read, create, reply to, edit, and moderate repository discussions |
| **Metadata** | Read | Repository identity and basic metadata; normally included automatically |
| **Actions** | Read | Inspect workflow runs, jobs, logs, and artifacts |
| **Workflows** | Write, only if needed | Create or edit workflow files and manage workflow configuration |
| **Commit statuses** | Write, only if needed | Post a pass/fail status from an external agent-run evaluation |

GitHub lists `contents`, `issues`, `pull_requests`, `discussions`, `actions`, `statuses`, and `workflows` as independent fine-grained repository permissions; `workflows` is write-only, so do not enable it merely because the agent reads CI results.

For most of your agent-mediated development, I would start with:

```text
Contents:       Read and write
Issues:         Read and write
Pull requests:  Read and write
Discussions:    Read and write
Actions:        Read
```

Then add **Commit statuses: write** only if a service external to GitHub Actions publishes a structured evaluation result to commits/PRs. Add **Workflows: write** only for an agent you explicitly authorize to change `.github/workflows/*` or workflow settings.

## Use separate capability tokens

Do not give every agent the full “developer” token. Split tokens according to operation class:

| Token | Permissions | Intended agent |
|---|---|---|
| `aipithicus-agent-triage` | Contents: read; Issues: RW; Discussions: RW; PRs: read | Issue/discussion intake, synthesis, labeling, roadmap maintenance |
| `aipithicus-agent-dev` | Contents: RW; Issues/PRs/Discussions: RW; Actions: read | Implementation agent that works on branches and opens PRs |
| `aipithicus-agent-ci-observer` | Contents: read; PRs: read; Actions: read | Review/evaluation agent that inspects code and CI but cannot mutate anything |
| `aipithicus-agent-release` | Contents: RW; Actions: RW if dispatch/rerun is required; optionally Discussions: RW | Deliberately gated release or maintenance automation |

That is especially useful for your multi-agent setup: a triage or reviewer agent should not silently acquire the ability to push source changes, alter CI, or administer repositories. Fine-grained tokens are explicitly designed for this repository- and permission-level containment.

## Permissions to avoid

Leave these off unless you have a concrete endpoint and a dedicated automation that needs them:

- **Administration: write** — repository settings, branch protection, and potentially destructive changes.
- **Secrets: write** or **Actions variables: write** — agents should never freely modify CI credentials or configuration.
- **Repository hooks: write** — allows adding/modifying outbound webhooks.
- **Deployments/Environments: write** — can affect deployment state and protection mechanisms.
- **Security alerts: write** — avoid letting a general-purpose agent dismiss or mutate security findings.
- **Pages: write** — unnecessary unless it deliberately publishes GitHub Pages content.

A PAT acts with the capabilities of its owning user, limited by the token’s grants; it cannot elevate beyond the user, but a broad token still exposes every action that user is already allowed to take.

## Token creation settings

Under **GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens**:

```text
Token name:        aipithicus-agent-dev
Resource owner:    Aipithicus
Repository access: Only select repositories
Expiration:        30–90 days initially
```

Select a small set of repos at first—e.g., the active public repos or a dedicated agent-sandbox repository—rather than “All repositories.” GitHub specifically advises choosing the minimum repository access and minimum permissions required, and supports expirations for fine-grained PATs.

Do **not** put the token in an agent prompt, repository config, committed `.env`, transcript, or issue/discussion. Treat it as a password; store it in your OS credential manager or your agent runner’s secret store, and rotate/revoke it if an agent environment, log, or context may have exposed it.

## If this means Actions

If the agent runs *inside* a GitHub Actions workflow, prefer the built-in `GITHUB_TOKEN` over a PAT. Declare exactly what that workflow needs:

```yaml
permissions:
  contents: write
  issues: write
  pull-requests: write
  discussions: write
  actions: read
```

GitHub recommends `GITHUB_TOKEN` for Actions authentication, with permissions set through the workflow’s `permissions` key. [docs.github](https://docs.github.com/en/rest/authentication/authenticating-to-the-rest-api?apiVersion=2026-03-10)

For a durable webhook-driven or always-on integration, graduate from PATs to a **GitHub App**: PATs are user-bound, while GitHub positions Apps as the better model for long-lived integrations and automation, including operational scaling beyond the 50 fine-grained-token limit.