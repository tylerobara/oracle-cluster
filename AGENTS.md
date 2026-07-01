# Oracle Cluster - GitOps Instructions

## Architecture

ArgoCD in-cluster GitOps managing a K3s cluster. A single Helm chart (`apps/_base`) renders ArgoCD `Application` resources from YAML config files across `apps/` subdirectories. Each app is deployed via its own Helm chart (community or third-party) with values overridden per-environment.

## Directory structure

- `apps/_base/` — Helm chart that generates ArgoCD Applications from values
- `apps/cluster/` — Cluster infrastructure (argocd, traefik, cert-manager, cloudnative-postgres, external-secrets, openbao, etc.)
- `apps/development/` — Dev tools (forgejo, gitea-mirror)
- `apps/home/` — Home services (haven, scribblers)
- `apps/monitoring/` — Monitoring stack (gatus, kube-prometheus-stack, ntfy)
- `apps/storage/` — Storage (longhorn)
- `k3s-upgrade/` — system-upgrade-controller Plan resources for K3s server/agent upgrades

## Adding an app

1. Create the app's directory under the appropriate category (`cluster`, `development`, `home`, `monitoring`, `storage`).
2. Add a `values.yaml` with the chart-specific values, nested under the app name key (e.g., `myapp:`).
3. If the chart needs extra templates, create a `templates/` directory alongside `values.yaml`.
4. In the category's config YAML (`apps/<category>/<category>.yaml`), add:
   ```yaml
   myapp:
     deploy: true
     namespace: <namespace>
   ```
5. Optional per-app overrides in the config YAML: `serverSideApply: true`, `ignoreDifferences: [...]`, `autoSync: false`.

## Key conventions

- **Deploy gating**: Set `deploy: false` to disable an app without removing it from config.
- **Namespace resolution**: If `namespace` is omitted, defaults to the app name.
- **ServerSideApply**: Use for apps that hit conflicts with standard apply (argocd, cloudnative-postgres, external-secrets).
- **ignoreDifferences**: Add webhook CA bundle drift entries when upgrading charts that regenerate Mutating/ValidatingWebhookConfiguration resources.
- **External secrets pattern**: Reference OpenBao via `ClusterSecretStore` named `oracle-cluster-secret-store`. Define in values.yaml under `externalSecrets:` with `secretStoreRef`, `target.name`, and `data[]` mapping remote keys to local secret keys.
- **Database pattern**: Apps needing databases create a CloudNative-PG Cluster via templates (see `apps/development/forgejo/templates/database/cluster.yaml`).

## K3s upgrades

Upgrades use system-upgrade-controller Plan resources in `k3s-upgrade/`. Server plan runs first (`concurrency: 1`, node selector matches `control-plane`), agent plan prepares then runs (node selector excludes `control-plane`). Edit version in both files before applying.

## Renovate

Configured in root `renovate.json`. All minor/patch updates are grouped under `"all-minor-patch"`. ArgoCD Application resources are matched via `apps/.+\\.yaml$` file pattern.

## Domain convention

All services use the `cloud.obara.xyz` domain (e.g., `git.cloud.obara.xyz`, `argo.cloud.obara.xyz`). Homepage integration uses `gethomepage.dev/*` annotations on ingress resources.
