# Independent deployment and rollback

## Activation gates

The current frontend uses [the CodeDeploy workflow](../.github/workflows/deploy.yml), not SSH.
Start with the [shared AWS foundation](../infra/codedeploy/) and the guarded steps below.
A merge does not constitute an installation, a production deployment, or a completed rollback drill.

1. Read the actual EC2 Node/npm versions, PM2 process names/CWD/script/uptime, Nginx configuration,
   active ports, free memory, and current artifact hashes. Record them outside Git without secrets.
   Node 24.14.1 is the validation runtime; verify compatibility on EC2 before activating deployment.
   Verify the non-interactive API service user also resolves this Node/npm version in PATH;
   an interactive NVM shell alone does not establish that.
2. Preserve `/var/www/private-mailhub`, its built assets, environment supply, and original worker.
   Confirm DB backup recovery is available. Do not initialize DB, run migrations, flush Redis, or rotate keys.
3. Freeze the old integrated workflow and production merges during cutover. Do not run it alongside
   the split workflows. Reconcile commits since the extraction snapshot first.
4. Provision Bash, tar, Python 3, Node/npm and util-linux `flock` on EC2.
   Provision both release/shared directories and a common `/var/lock/mailhub-deploy.lock` writable
   by the deploy user. Both repositories must use the same lock. Restrict deploy account permissions.
5. Provision the backend shared `.env` outside Git/artifacts. Match original keys, DB, Redis, AWS,
   Mailgun and CORS settings. CWD-based loading requires each release `.env` symlink. Worker also
   needs all shared validation values including PORT. Keep VITE_* build settings only in FE.
6. Restrict each GitHub `production` environment to reviewed `main`, with approval rules where available. Use repo-specific OIDC roles, deployment groups, and artifact prefixes. No runner SSH, ingress changes, static AWS keys, or runtime `.env` in Actions.
7. Supply only FE `VITE_API_URL`; production must be an HTTPS origin without a path. The browser
   must never receive `ENCRYPTION_KEY` or any other backend encryption key, and Vite's envPrefix
   must not be widened.
8. Validate mixed client/API versions in an isolated environment and the browser scenarios below.

## Release order and key-management gate

The repositories are versioned and deployed independently, but the API contract changes must be
rolled out in a compatible order:

1. If the current API lacks the new contract, prepare and deploy the `backend` release first. Keep the previous API available until
   plaintext username payloads (`username`, `code`, and `newUsername`) and the existing refresh
   and OAuth flows have been verified with a controlled account.
2. Build and deploy the `frontend` release second, using the canonical production API origin (`https://private-mailhub.com`, no `/api` suffix). Verify old-client/new-API and new-client/new-API before
   removing the old release. New-client/old-API is intentionally unsupported because the old API
   rejects the new plaintext field names; rollback the frontend before rolling back the API.
3. Keep both deployment workflows disabled until environment approvals, branch restrictions,
   OIDC trust, HTTPS, and rollback checks are recorded. Do not activate both workflows in parallel
   during the first cutover.

Backend encryption keys are server-only operational secrets. Key rotation is a separate gate from
repository separation: create a versioned key and migration/re-encryption plan, validate that all
stored records can be read during the transition, rotate or revoke affected OAuth credentials when
required, and retain a tested rollback path. Never copy a backend key into `.env.example`, Vite
variables, static assets, browser storage, workflow logs, or release archives.

The first migration to the new FE root or API upstream is an explicit maintenance action. The CI runner must not edit live Nginx configuration. Never build in a serving directory.

## Initial frontend transition

After the first hosting bootstrap, dispatch the workflow on reviewed `main`. It validates and builds frontend only,
publishes `/var/www/mailhub-frontend/releases/<sha>`, copies assets additively to `shared/assets/`,
and atomically switches `current`. Record the previous current target first. It never invokes PM2.

Before initially installing the backend-owned `deploy/nginx.conf`, copy the **existing production**
`front-end/dist/assets/` into the new shared asset directory without deleting existing hashes.
This keeps previously open browser tabs working. Also populate the first new FE release before
pointing Nginx at it. Keep the old checkout available for rollback.
After the keyless client is fully cut over and the server key is rotated, remove archived assets
that contain the retired browser key so append-only preservation does not keep it downloadable.

Create `/etc/nginx/mailhub-backend-upstream.conf` with the observed current API endpoint (8080
in the template, but verify it), for example:

```nginx
server 127.0.0.1:8080 max_fails=3 fail_timeout=30s;
```

Back up the effective Nginx site and upstream files. Compare the template with the effective
configuration, preserving TLS, domains, proxy address/header chain and any operational overrides.
Under the common flock, install the reviewed site, run `sudo nginx -t`, and only then reload.
On test failure, restore the configuration before releasing the lock. Keep the existing canonical redirect and ACME exception; HTTPS must reach the expected upstream and FE root. Check static files, `/assets/`, index.html, public files, and SPA fallback.

## Independent API and worker operation

API activation must never replace the running worker, change its working directory, or garbage-collect its release. API candidate, authenticated readiness and guarded rollback are maintained in the backend [API runbook](https://github.com/private-mailhub/backend/blob/main/docs/api-codedeploy.md). If that implementation has not merged, keep the PM2 worker pinned and use the last reviewed operating procedure. Lambda cutover is a separate change; do not enable an SQS mapping or change worker count as a side effect of a frontend or API release.

## Independent rollback

Hold the same server lock and record exact current/previous release identities.

- **FE:** create a temporary symlink beside `current` to the recorded previous release, then
  `mv -Tf` it over `current`. Keep shared hash assets. On first migration the Nginx site backup
  can restore the original checkout if necessary. API/worker processes remain unchanged.
- **API:** start/verify the previous API at its recorded port if it was stopped. Restore upstream,
  run `nginx -t`, reload, verify public and session checks, then stop the failed candidate only.
- **Worker:** use a separate, drain-aware cutover runbook and the same durable delivery ledger in both consumers. Never start an older non-ledger consumer during a Lambda rollback. An API or FE rollback must not change the consumer.

No DB reverse migration, Redis flush, or key regeneration belongs to separation rollback.
Keep previous artifacts, refs, and backups until the rollback window has been explicitly closed.

## Acceptance record

For each deployment record SHA, release paths, previous targets, Node/npm versions, PM2 names/ports,
Nginx site/upstream paths, timestamps and validation outcomes in the operational change record.
Do not commit secrets, token-bearing responses or personal data.

Verify old FE/new BE and new/new. New FE/old BE is intentionally unsupported, so rollback must
restore the old FE before the old BE. Verify existing login refresh/cookie rotation/logout;
email verification; GitHub/Google login/link/revoke; callback error/deep-link reload; relay CRUD;
profile/admin views; stale tabs/assets/new tabs/back navigation; controlled mail/reply masking/SQS.
Frontend-only deployment must preserve API/worker PID and uptime. Backend-only deployment must
preserve FE current and file hashes. Repeat public, session and mail checks after each rollback.
Only then unfreeze production automation and mark the operational split complete.

## First CodeDeploy rehearsal

1. Confirm the exact EC2 target and agent identity. The frontend hooks run as `ubuntu`; that account must already own the frontend release tree and be able to write the common lock, without sudo, PM2 or access to server credentials. Confirm the running host, Nginx paths, runtime, and previous local TLS release by inspection, not from the template. Use the foundation stack outputs for `AWS_REGION`, `AWS_ROLE_ARN`, `DEPLOY_BUCKET`, `CODEDEPLOY_APP`, `CODEDEPLOY_GROUP`.
2. If Nginx still serves the original checkout, first seed a **known-compatible, identifiable** baseline release, preserve old hashed assets, and recheck the live homepage and its JS. For a pre-CodeDeploy `current`, replay its exact baseline artifact to verify and seal the whole existing tree before switching to a new SHA. If no matching original artifact is available, use an operator-reviewed separate bootstrap and retain the old Nginx root as fallback; do not treat an unknown tree as sealed. Only switch the Nginx root after `nginx -t` and with the original configuration backed up. Do not rely on CodeDeploy to roll back an unseeded first deployment.
3. Leave repository `CODEDEPLOY_ENABLED` and both projects' automatic triggers disabled until role trust, release root, local HTTPS validation and existing API compatibility are established. Enable manual deployment first. Build tests use a test URL; only the final clean rebuild uses the production API origin. Artifacts never include the runtime environment or backend keys.
4. Record the CodeDeploy deployment ID, Git SHA, S3 key and **VersionId**. Rehearse selected revision → previous successful revision → selected revision using exact immutable S3 versions. Confirm the old asset URL still works and API/worker PID and uptime do not change. Check the real `https://private-mailhub.com/` each time, including after rollback. Revisit an authenticated dashboard and verify session refresh without logging cookies or user addresses.
5. `CODEDEPLOY_AUTO_ENABLED=true` (repository variable) enables pushes to `main` only if the manual gate is also on. Only enable automatic releases after the manual drill passes. On a failed public probe, inspect CodeDeploy state and target SHA; a runner-side HTTP failure is not proof that the host has already rolled back. Never replace the worker, modify DNS, or restart all processes to recover a frontend deployment.

For a cross-repository contract change, disable both automatic switches, cancel obsolete queued workflow runs, and serialize the compatible API and frontend revisions under the change record. The common host lock prevents concurrent changes, not an incorrect release order. Resume independent automatic releases only after verifying the new pair.
