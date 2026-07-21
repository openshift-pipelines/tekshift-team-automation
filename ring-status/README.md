# ring-status

Post-upgrade health checks for OpenShift Pipelines / pipeline-service style clusters.

This small checkout contains:

| File | Purpose |
|------|---------|
| `ring-status.sh` | CLI that runs CatalogSource, TektonConfig, Subscription, pod, PaC (and optional `--verify`) checks |
| `ring-mappings.yaml` | Maps production cluster names → rings (1/2/3) for `--ring` / `--cluster` |
| `rs-devbootstrap.yaml` | Minimal TektonConfig + CatalogSource + Subscription to stand up a testable cluster |

## Why `ring-mappings.yaml` alone is not enough to test

`ring-mappings.yaml` lists **real production cluster names** (e.g. `stone-prod-p01`).  
`ring-status.sh --cluster` / `--ring` expects:

1. Those names to exist in the YAML, **and**
2. A kubeconfig **context with the same name** that can reach that OpenShift cluster.

Most people (and CI) will not have SSO/`oc` access to those prod rings. A local kind cluster also will not work — these checks need OpenShift APIs (`CatalogSource`, `TektonConfig`, etc.).

So for development and demos, you CAN treat ring-mappings as the **intended production targeting model**, not as something you can exercise end-to-end without prod credentials.

## Recommended test setup (cluster-bot + bootstrap)

1. Create an OpenShift cluster with **cluster-bot** (or equivalent ephemeral OCP).
2. `oc login` to that cluster (use whatever context name cluster-bot gives you).
3. Apply the bootstrap:
   ```bash
   oc apply -f rs-devbootstrap.yaml