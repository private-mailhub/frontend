# Optional first EC2 instance profile

Use [host-identity.yaml](host-identity.yaml) only for a verified host with **no instance profile**. It is a separate, opt-in stack in `us-east-1`, not part of the [CodeDeploy foundation](../README.md). It creates a generated-name role trusted only by `ec2.amazonaws.com` and a generated-name instance profile containing only that role. There are no parameters, managed or inline permission policies, EC2 associations, tags, custom resources or deployments. CI tests the template but never provisions it. The region guard applies to the stack; IAM identities are account-wide.

| Output (friendly name, not an ARN) | Consumer |
| --- | --- |
| `InstanceRoleName` | The foundation's `ExistingInstanceRoleName`, only after separate attachment review. |
| `InstanceProfileName` | The EC2 owner, only for an approved first association. Not a role name. |

Review locally from the repository root:

```sh
ruby infra/codedeploy/host-identity/test_host_identity.rb
ruby infra/codedeploy/test_foundation.rb
```

These inspect template structure offline. They do not verify account state, effective permissions, application behavior or a deployment. The gates below are **future operator actions**, not part of testing or merging this change.

## Before changing IAM or EC2

- Keep both frontend and API release workflows disabled, including manual and automatic triggers. Verify no deployments are in flight. Agree on one change owner and a window with the IAM, EC2 and application owners; pause competing host or provisioning changes.
- Using established read-only access, confirm the account, `us-east-1`, the one intended running host, its target tags and its provisioning/launch-template owner. Check **both** the instance's IAM profile field and its profile association records, including transitions. If a profile already exists, **skip this stack**: resolve the actual role inside that profile, its trust, attached and inline policies and other consumers with its owner. Never replace or disassociate an active profile. Stop on conflicting inventory, pending changes, or automation that could attach one.
- **A first profile changes the credential chain, even with no identity policies.** Every process that can reach IMDS may acquire the role's temporary credentials, not just CodeDeploy. A legacy SDK, API, worker, cron job or maintenance tool that previously found no credentials (or later loses a higher-priority provider) may start signing as the host role. Explicit or higher-priority credentials can still win. Inventory provider settings and record the effective credential source/principal or absence in the actual service contexts; do not dump environments, tokens, keys or metadata credential responses. Check resource-based grants as well as identity policies. Baseline service health and required AWS access, rehearse on an isolated host and agree on a recovery path. If an identity change or its effect is unexplained, stop before association.

## Approved operator sequence

1. The IAM owner reviews a **create-only** change set in the verified account and region (`CAPABILITY_IAM`): exactly the two additions above, no imports or other changes. Check there is no earlier stack or retained pair for this host. Only after separate approval, execute that change set and verify stack termination protection is enabled before use. Record both output names in the private change record. In IAM, verify sole EC2 trust, **zero** attached and inline policies, exactly this role in the new profile and no other consumers. Stop on drift or ambiguous ownership.
2. If tagging is needed, only the EC2 owner may apply the separately approved, dedicated target tag. Check for unintended matches immediately before tagging; stop if any exist. Verify exactly the intended host and no other nonterminated matches afterward. Repeat the [foundation target inventory check](../README.md) before its change set.
3. Leave `ExistingInstanceRoleName` empty until the foundation attachment is separately approved. If it already names a different role, stop: switching it can detach a live consumer. Set it to **`InstanceRoleName`**, never the profile name or an ARN. Before proceeding for CodeDeploy, verify the role has only the foundation's `InstanceReadPolicyArn` (read/version-read on the two artifact prefixes) and no inline policies. Do not duplicate ownership or add policies here.
4. **Immediately before association**, the EC2 owner re-reads the intended host's profile field and association records. Confirm both still show no current or pending profile, and recheck the approved profile-to-role mapping. Only then associate `InstanceProfileName` as the **first** profile under the approved window. If a profile appeared, state is transitioning, or the request conflicts or times out, stop and re-inventory. Do not retry blindly, replace or disassociate a live profile.
5. Wait for the expected association to be established and IAM to propagate. Verify the expected temporary identity via IMDSv2 without exposing credentials. In the actual legacy service contexts compare credential selection, required access and health with baseline. Verify the CodeDeploy agent and a known, disposable, exact-version artifact read in rehearsal; do not upload or release as a probe. On mismatch, stop and use the agreed recovery path, not extra permissions or static keys. Keep both workflows disabled until a **separate release approval** clears all foundation gates.

## Retention and retirement

Both resources use `DeletionPolicy: Retain` and `UpdateReplacePolicy: Retain`. Deleting the stack leaves the identities behind and outside stack management. Replacement can **still create a different identity** while retaining the old one; retention does not protect against in-place trust or profile membership changes. Keep logical IDs stable, keep termination protection on and protect both resources from updates with a stack policy. Reject change sets that remove, replace (including conditional replacement) or modify an in-use identity. Do not recreate a stack to recover lost output names.

Before any handoff or retirement, keep releases disabled, reconcile retained names and confirm all associations, attached policies and consumers with both owners. Do not detach a policy still needed by a host or its rollback. Retire the host association in a separately approved decommissioning window after consumers are drained; allow issued credentials to expire. Clear the foundation's `ExistingInstanceRoleName` through its owner and verify the attachment is gone. Only when no users or associations remain may the IAM owner remove the role from the retained profile, then delete the unused profile and role under explicit cleanup approval. Stack deletion is not a cleanup or rollback procedure.
