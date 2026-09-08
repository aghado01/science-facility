## Everyday issue operations

```nu
# Survey
gh issue status
gh issue list
gh issue list --label "area:engine"
gh issue list --milestone "Repository bootstrap"

# Structured output for agents
gh issue list --json number,title,state,labels,milestone,url
gh issue view 12 --json number,title,body,state,labels,comments,url

# Create
gh issue create
gh issue create --title "Repair project topology" --label "area:repository"
gh issue create --title "..." --body-file issue.md

# Update
gh issue edit 12 --add-label "priority:P1"
gh issue edit 12 --milestone "Repository bootstrap"
gh issue comment 12 --body "Project graph has been repaired."

# Lifecycle
gh issue close 12 --comment "Completed and verified."
gh issue reopen 12
```

`--json` and `--jq` make these especially usable by local agents:

```nu
gh issue list --json number,title,labels
  | from json
  | where state == "OPEN"
```

## Connecting Git work to issues

Create a linked branch when desired:

```nu
gh issue develop 12 --checkout
```

For your normal direct-to-`main` workflow:

```nu
git commit -m "Repair project ownership" -m "Refs #12"
git push
```

To close the issue when that commit reaches the default branch:

```nu
git commit -m "Repair project ownership" -m "Fixes #12"
```

For contributed PRs:

```nu
gh pr create --title "Repair project ownership" --body "Closes #12"
```

GitHub recognizes closing keywords in commit messages and PR descriptions. [GitHub issue-linking documentation](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/linking-a-pull-request-to-an-issue)

## Labels and Projects

Labels are fully manageable locally:

```nu
gh label list
gh label create "area:engine" --color "1D76DB"
gh label create "type:design" --color "5319E7"
gh label edit "bug" --description "Confirmed incorrect behavior"
```

Projects are also CLI-accessible:

```nu
gh project list --owner "@me"
gh project create --owner "@me" --title "Aipithicus Development"
gh project link 1 --owner "@me" --repo OWNER/Doccer
gh project field-list 1 --owner "@me"
gh project item-list 1 --owner "@me"
```

An issue can be created directly in a Project:

```nu
gh issue create --title "..." --project "Aipithicus Development"
```

The `project` scope is required. [GitHub CLI Projects manual](https://cli.github.com/manual/gh_project). High-level flags for:

- `--parent`
- `--blocked-by`
- `--blocking`
- `--type`

```nu
gh issue create --title "Child task" --parent 12
gh issue create --title "Restore baseline" --blocked-by 13
```

Alternatively:

```nu
gh api ...
gh api graphql ...
```

So the simple operating model is:

```text
git  → commits, branches, tags, remotes
gh   → GitHub issues, PRs, labels, milestones, Projects, releases
```
