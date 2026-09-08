## Initial local setup

Once Doccer has a remote:

```nu
gh auth login
gh auth status

git config --local user.name "YOUR AIPITHICUS NAME"
git config --local user.email "YOUR AIPITHICUS EMAIL"

gh repo set-default OWNER/Doccer
```

Projects require the additional scope:

```nu
gh auth refresh -s project
```

Your current `gh` installation is present but not authenticated.
