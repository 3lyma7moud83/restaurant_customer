# Secrets Incident Runbook (Production Safe)

This runbook handles:
1. Credential rotation without downtime.
2. Git history cleanup for leaked secret files.
3. Repository hardening to prevent re-leak.

## 1) Rotation Order (No Downtime)

Use this exact order to avoid interruption:

1. Create replacement credentials first.
2. Update runtime secrets in production.
3. Deploy/restart affected backend services.
4. Verify traffic and delivery health.
5. Revoke old credentials only after successful verification.

### Minimum required rotation for this incident

1. `FIREBASE_SERVICE_ACCOUNT_JSON` key pair (critical).
2. Any Supabase service-role secret if it was exposed outside secret storage.
3. Optional: rotate non-secret/public client keys only if policy requires it.

## 2) Git History Cleanup

Run only after step (1) is complete.

### 2.1 Install `git-filter-repo` (if needed)

```powershell
pip install git-filter-repo
```

### 2.2 Backup mirror clone

```powershell
git clone --mirror <YOUR_REMOTE_URL> repo-cleanup.git
cd repo-cleanup.git
```

### 2.3 Remove leaked secret paths from history

```powershell
git filter-repo `
  --path supabase.env `
  --path assets/env/app.env `
  --path assets/assets/env/app.env `
  --invert-paths
```

### 2.4 Force-push rewritten history

```powershell
git push --force --all
git push --force --tags
```

### 2.5 Team recovery

All contributors must re-clone (or hard-reset to new history) after rewrite.

## 3) Repo Hardening (implemented)

1. `supabase.env` is ignored.
2. `assets/**/env/app.env` is ignored.
3. Build-generated `assets/assets/env/` is ignored.
4. `supabase.env.example` added as safe template.

## 4) Verification Checklist

1. `git status --short` does not show accidental secret tracking from ignored files.
2. `git ls-files | rg "supabase\\.env|app\\.env"` returns only safe example files.
3. Notification processing health remains green after secret rotation.
4. Old Firebase key is disabled only after successful function verification.
