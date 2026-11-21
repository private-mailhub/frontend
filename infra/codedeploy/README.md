# Shared EC2 CodeDeploy foundation

[foundation.yaml](foundation.yaml) is **one stack, owned here**, for `private-mailhub/frontend` and `private-mailhub/backend` in `us-east-1`. Provisioning the stack does **not** deploy code. It creates a private artifact bucket, two OIDC roles, two `Server` applications with separate in-place deployment groups, a discovery service role and an optional host-policy attachment. It creates no EC2 host, instance profile, SSH/security-group rule, NAT, endpoint, load balancer or DNS record. Do not deploy a second copy from the API repository.

## Review locally (no AWS or GitHub calls)

```sh
ruby infra/codedeploy/test_foundation.rb
# Optional additional offline schema check with cfn-lint installed:
cfn-lint -r us-east-1 -t infra/codedeploy/foundation.yaml
```

The tests inspect trust, allowed action/resource pairs, host selection, bucket retention, the attachment switch and the output contract. They do not claim connectivity, effective account permissions or a successful production deployment.

## Operator gates before provisioning or releasing

1. **Repository protection, both repos.** Create the `production` environment first. Choose *Selected branches and tags*, permit only the **branch** `main`, and add **no tags** (including a tag named `main`). Protect `main` and workflow changes with required reviews/checks. Require environment reviewers, prevent self-review and disallow bypass where available. If the repository's plan/settings cannot enforce this protection, do not activate. The deployment job must use `environment: production`, `id-token: write` and `contents: read`; do not grant the token to PR builds or arbitrary refs. The environment OIDC `sub` does **not** include the branch: a workflow-level branch check is not a substitute for the environment rule.
2. **OIDC identity.** Supply the ARN of the **existing, same-account** IAM OIDC provider for `https://token.actions.githubusercontent.com` with audience `sts.amazonaws.com`. Do not create another provider, or configure long-lived AWS keys. Confirm each repository's claim configuration emits exactly `repo:private-mailhub/frontend:environment:production` or `repo:private-mailhub/backend:environment:production`, respectively. GitHub also supports [immutable or customized subjects](https://docs.github.com/en/actions/reference/security/oidc); if they differ, the roles intentionally fail closed. Review a change to the *exact* verified subject before activation; never replace it with a wildcard. Do not print JWTs.
3. **Target inventory.** `HostTagKey` and `HostTagValue` have no default. Use a dedicated nonempty EC2 tag, not a common `Environment=production` label. Restrict who can change it. Both groups select **every** instance with that exact key/value in the stack account/region. With an operator's read-only identity, check before creation, before **each** release and after tag changes:

   ```sh
   aws ec2 describe-instances --region us-east-1 \
     --filters "Name=tag:${HOST_TAG_KEY:?},Values=${HOST_TAG_VALUE:?}" \
     --query 'Reservations[].Instances[].[InstanceId,State.Name,IamInstanceProfile.Arn]' --output table
   ```

   Confirm exactly one intended running instance, and no other nonterminated matches (including stopped/standby hosts). Stop if there are zero or extra targets; this template does not tag hosts or enforce a host count. Do not put actual IDs, profile names or network details in source control.
4. **Agent and instance identity.** Identify the actual role *inside* the instance's existing profile (its name can differ from the profile name). Verify the CodeDeploy agent is installed, supported and running; IMDS credentials, DNS, time and **outbound HTTPS** to the regional CodeDeploy agent endpoint and S3 must work. Never open inbound SSH or application ports for deployment. Agent installation/update access to the regional AWS resource-kit bucket is separate from release artifact access. For an existing PrivateLink topology, also verify the S3 path and both regional CodeDeploy endpoints; enable authenticated agent commands and separately review the four `codedeploy-commands-secure` agent permissions [required by AWS](https://docs.aws.amazon.com/codedeploy/latest/userguide/vpc-endpoints.html). This stack does not create endpoints, NAT or grant those acknowledgement/write actions as part of an artifact **read** policy.
5. **Host attachment.** Leave `ExistingInstanceRoleName` empty to create `InstanceReadPolicyArn` **unattached**. For an existing role dedicated to this host, either supply the verified role's **friendly name** (not ARN/profile name/path) for an additive managed-policy attachment, or let its IAM owner attach the output policy in the role's existing infrastructure. Choose one owner, not both. A shared role would grant every user of that role artifact reads: do not attach without reviewing its consumers. No profile or existing policy is replaced. Stack-managed attachments are removed on stack deletion; plan ownership/transfer first if needed.
   **If the instance has no IAM profile:** leave the parameter empty and keep both workflows disabled. In a separate authorized bootstrap change, the IAM/EC2 owner creates a dedicated role trusted by `ec2.amazonaws.com`, puts it in a dedicated instance profile and gives that role the output artifact-read policy. Immediately re-read the intended instance's profile association: associate this **first** profile only if no profile exists. If one appeared meanwhile, stop and review; never replace or disassociate a live profile to make this work. Confirm the association is established, the agent obtains temporary credentials via IMDS and it can retrieve a known disposable, version-pinned test object in a rehearsal. Do not expose credentials, upload a release as a probe or use SSH/static AWS keys as a workaround. Only then clear the host-identity gate. The template itself performs none of these bootstrap actions.
6. **Shared host and baseline.** Verify both bundles' AppSpec hooks, ownership, release directories, common host lock and service-level health checks in an isolated host rehearsal. GitHub concurrency groups are scoped to a repository, not across both repos. Serialize cutover and rollback; never run competing activations. Separate IAM roles prevent cross-prefix uploads and cross-group deployment calls, but are **not** an OS security boundary: both approved revisions run hooks on one machine. CodeDeploy IAM has no condition binding a revision's S3 key to a group. Protect both repositories as production code and limit host runtime privileges accordingly.

## Controlled provisioning (separate operator action)

Keep release workflows disabled. Check the intended AWS account using the operator's established access process. Use the template as a local file, without a packaging/upload step. Example **for a future authorized change window**; `--no-execute-changeset` creates a change set in AWS but does not apply it. Nothing here needs to run to review or test the PR.

```sh
aws cloudformation deploy --region us-east-1 --stack-name mailhub-codedeploy \
  --template-file infra/codedeploy/foundation.yaml --capabilities CAPABILITY_IAM \
  --parameter-overrides "GitHubOidcProviderArn=${OIDC_PROVIDER_ARN:?}" \
    "HostTagKey=${HOST_TAG_KEY:?}" "HostTagValue=${HOST_TAG_VALUE:?}" \
    "ExistingInstanceRoleName=${INSTANCE_ROLE_NAME:-}" --no-execute-changeset
```

Review the change set, especially role attachments, replacements and target filters. The IAM resources have generated names. Only a separately authorized operator executes the reviewed change set. No group `Deployment` property, custom resource or release trigger is present. A group replacement can discard its known-good history; do not replace it or the bucket as a routine update. After approval/application, read the outputs with `aws cloudformation describe-stacks --region us-east-1 --stack-name mailhub-codedeploy --query 'Stacks[0].Outputs'` and configure **each repository's protected `production` environment**:

| Runner variable | `private-mailhub/frontend` output | `private-mailhub/backend` output |
| --- | --- | --- |
| `AWS_REGION` | `Region` (`us-east-1`) | `Region` (`us-east-1`) |
| `AWS_ROLE_ARN` | `FrontendRoleArn` | `ApiRoleArn` |
| `DEPLOY_BUCKET` | `DeployBucket` | `DeployBucket` |
| `CODEDEPLOY_APP` | `FrontendApp` | `ApiApp` |
| `CODEDEPLOY_GROUP` | `FrontendGroup` | `ApiGroup` |
| S3 key prefix, fixed in runner | `frontend/` | `api/` |

Do not enable either workflow just because the stack exists. Check the gates above and allow for initial propagation of S3 versioning ([AWS recommends waiting 15 minutes after first enabling](https://docs.aws.amazon.com/AmazonS3/latest/userguide/manage-versioning-examples.html)). Keep the existing independently recoverable production baseline until each group's first successful deployment is verified.

## Runner/API contract

Use pinned, reviewed workflow steps and short-lived GitHub OIDC credentials. The two roles support the same sequence, scoped to different resources:

1. `aws s3api get-bucket-versioning --bucket "$DEPLOY_BUCKET" --query Status --output text` must return **Enabled**. Fail closed on any other result, including an error.
2. Single-request `aws s3api put-object` on a unique key under the assigned prefix (e.g. commit SHA plus run ID/attempt), with `--body`, `--if-none-match '*'` and optional metadata. Capture **`VersionId` from that very response**. Reject empty, `None` or `null`. A collision/HTTP 412 is not a successful upload; never discover "latest" or overwrite an existing key on retry. A fresh attempt can use a new key. No HeadObject, ListBucket, delete, ACL or multipart rights are needed. Do not include `.env`, keys, cloud credentials or untracked host files in a revision.
3. Call `aws deploy create-deployment` with **this** app and group, the exact `{bucket,key,bundleType,version}` from the upload and an AppSpec at the bundle root. Never send an unversioned revision, a different region, an alarm override or `targetInstances`. For example, with shell locals set by the runner:

   ```sh
   revision=$(jq -nc --arg b "$DEPLOY_BUCKET" --arg k "$key" --arg t "$bundle_type" --arg v "$version" \
     '{revisionType:"S3",s3Location:{bucket:$b,key:$k,bundleType:$t,version:$v}}')
   aws deploy create-deployment --region "$AWS_REGION" --application-name "$CODEDEPLOY_APP" \
     --deployment-group-name "$CODEDEPLOY_GROUP" --revision "$revision" --query deploymentId --output text
   ```

4. Record the deployment ID, commit, artifact digest, bucket/key and **version**. Poll `aws deploy get-deployment --deployment-id "$id" --query deploymentInfo.status --output text` with bounded retries/time. Only `Succeeded` is success; `Failed`, `Stopped`, invalid IDs, lost authorization and exhausted polling must not report success. A cancelled/timed-out workflow does not stop CodeDeploy: an operator must reconcile the ID before another release. Confirm application health after hooks, not just upload acceptance.

### Why these IAM permissions

Verified against the AWS [Service Authorization Reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_awscodedeploy.html) and [CodeDeploy permissions reference, including the CreateDeployment footnote](https://docs.aws.amazon.com/codedeploy/latest/userguide/auth-and-access-control-permissions-reference.html):

| Runner IAM action(s) | Authorized resource |
| --- | --- |
| `s3:GetBucketVersioning` | The generated bucket ARN, no object suffix |
| `s3:PutObject` | Only the generated bucket's own `frontend/*` or `api/*` object ARNs |
| `codedeploy:CreateDeployment`, `codedeploy:GetDeployment` | Exact `deploymentgroup:APP/GROUP` ARN in this account/region; polling accepts an ID, but there is **no deployment-ID ARN** |
| `codedeploy:RegisterApplicationRevision`, `codedeploy:GetApplicationRevision` | Exact `application:APP` ARN for registering a new revision or accessing an existing one during creation |
| `codedeploy:GetDeploymentConfig` | Exact `deploymentconfig:CodeDeployDefault.OneAtATime` ARN in this account/region |

`UpdateDeploymentGroup` would be needed for `overrideAlarmConfiguration`; the jobs do neither. No wildcard CodeDeploy policy, `List*`, `iam:PassRole`, SG modification, console access or S3 read is granted to the runner. The **service** role trusts only the regional CodeDeploy endpoint and can only discover EC2 instances/status/tags in `us-east-1`. These discovery reads have no instance-scoped ARN; the group filters choose the target. The **host** policy reads both artifact prefixes with only `GetObject`/`GetObjectVersion`; it cannot list, upload or deploy. Review any pre-existing host permissions separately.

## Rollback, retention and decommissioning

- Each group has `DEPLOYMENT_FAILURE` automatic rollback. CodeDeploy creates a **new deployment ID** for the last successful revision of *that group*. Check both the failed ID and any rollback ID, plus actual service health. The first deployment, or the first after recreating a group, has no known-good revision to redeploy. Keep a tested out-of-band host recovery path and previous runnable release; establish and verify a known-good baseline per group before relying on automatic rollback.
- A hook must return failure on bad health. CodeDeploy cannot reverse irreversible script effects, migrations, external resources or shared-host concurrency. Do not infer API/worker health from a frontend success. A manual redeployment must use the recorded **exact** known-good version; never substitute the current object version. See [AWS rollback behavior](https://docs.aws.amazon.com/codedeploy/latest/userguide/deployments-rollback-and-redeploy.html).
- SSE-S3 encryption, bucket-owner-enforced ownership, all four public access blocks and explicit HTTPS-only access are enabled. Current **and noncurrent** objects have no expiration or archival transition. Lifecycle aborts only unfinished multipart uploads after seven days. The bucket and TLS deny policy are retained on stack deletion/replacement; storage costs continue. Versioning is not Object Lock: administrators can still delete versions or change retention. Disable workflows and confirm no active deployments before decommissioning; inventory every live/rollback version (including retained buckets) and separately approve any eventual deletion or policy handoff.
