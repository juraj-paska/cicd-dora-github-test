# cicd-dora-github-test

A tiny Flask website used to exercise a full CI/CD path: build → containerize →
push to Amazon ECR → deploy to EKS, with SolarWinds APM (via OpenTelemetry
auto-instrumentation) reporting to two collectors.

## What's in here

| Path | Purpose |
| --- | --- |
| [app.py](app.py) | Flask app. Serves a page on `/` and a health check on `/health`. The heading shows the pipeline run number when built by CI. |
| [requirements.txt](requirements.txt) | `flask`, `gunicorn`, `solarwinds-apm`. |
| [Dockerfile](Dockerfile) | Python 3.13 slim image, non-root user, `$PORT`-configurable, runs gunicorn under `opentelemetry-instrument`. |
| [.github/workflows/build.yaml](.github/workflows/build.yaml) | The CI/CD pipeline (`prep` → `test` → `build-image` → `deploy`). |
| [k8s/](k8s/) | Kubernetes manifests (namespace, workloads, services, secret template). |

## The application

- `GET /` — HTML page: **Hello from cicd-dora-github-test `<run-number>`**. The
  run number is baked into the image at build time (`RUN_NUMBER` build arg →
  env var). Locally, where it isn't set, the heading is just
  `Hello from cicd-dora-github-test`.
- `GET /health` — returns `{"status": "ok"}` with HTTP 200.

The port is configurable via `$PORT` (default `8080`), so the same image runs
as multiple containers in one pod on different ports.

### Run locally

```bash
pip install -r requirements.txt
python app.py                 # dev server on http://localhost:8080
# or, mirroring the container:
RUN_NUMBER=local gunicorn --bind 0.0.0.0:8080 app:app
```

## Observability (SolarWinds APM)

APM is enabled by OpenTelemetry auto-instrumentation baked into the image. Each
pod runs the site **twice** so it reports to two collectors:

- `website-staging` — port `8080`, staging collector
  (`apm.collector.na-01.st-ssp.solarwinds.com`).
- `website-dev` — port `8081`, dev collector
  (`apm.collector.na-01.dev-ssp.solarwinds.com`).

Each workload reports under a **distinct service name** (via `OTEL_SERVICE_NAME`
/ `OTEL_RESOURCE_ATTRIBUTES`), so they show up separately in SolarWinds:

- Deployment → `cicd-dora-github-test-deployment`
- StatefulSet → `cicd-dora-github-test-statefulset`
- DaemonSet → `cicd-dora-github-test-daemonset`

The `SW_APM_SERVICE_KEY` (`<ingestion-token>:<service-name>`) is stored in two
K8s Secrets, one per collector. **Token material is never committed** — see
[Secrets](#secrets) below.

## Kubernetes workloads

All manifests live in [k8s/](k8s/) and target namespace
`cicd-dora-github-test`. They contain the three workloads plus their services
(the `.example` file is ignored — kubectl only reads `.yaml`/`.yml`/`.json`).

The app image tag in the manifests is the literal `IMAGE_TAG_PLACEHOLDER`; the
pipeline substitutes this commit's short SHA at deploy time before applying. To
apply by hand, render the tag first, e.g.:

```bash
mkdir -p rendered
for f in k8s/*.yaml; do
  sed "s/IMAGE_TAG_PLACEHOLDER/<short-sha>/g" "$f" > "rendered/$(basename "$f")"
done
kubectl apply -f rendered/
```

| File | Object(s) |
| --- | --- |
| [k8s/00-namespace.yaml](k8s/00-namespace.yaml) | Namespace |
| [k8s/cicd-dora-github-test-website.yaml](k8s/cicd-dora-github-test-website.yaml) | Deployment + ClusterIP Service |
| [k8s/statefulset.yaml](k8s/statefulset.yaml) | StatefulSet + headless Service |
| [k8s/daemonset.yaml](k8s/daemonset.yaml) | DaemonSet (one pod per eligible node) |
| [k8s/01-secret.yaml.example](k8s/01-secret.yaml.example) | Template for the APM Secrets (not applied by CI) |

Each pod has three containers: `website-staging`, `website-dev`, and a
`traffic-generator` sidecar that curls both ports on a loop to generate APM
traffic. A `nodeSelector` (`kubernetes.io/arch=amd64`, `kubernetes.io/os=linux`)
is required by the cluster's Gatekeeper `podnodeselector` policy.

## CI/CD pipeline

Workflow: **Build-cicd-dora-github-test**
([.github/workflows/build.yaml](.github/workflows/build.yaml)).

### Triggers

- **push** to `main` — full run: build a new image and deploy it.
- **pull_request** to `main` — builds the image but does **not** push or deploy
  (validation only).
- **workflow_dispatch** (manual) — run from the Actions tab with the options
  below.

### Jobs

```
prep ─┐
      ├─> build-image ─> deploy
test ─┘
```

- **prep** — computes the short commit SHA used as the image tag.
- **test** — dummy test step. Passes by default; can be forced to fail on a
  manual run (see options). A failure blocks `build-image` and `deploy`.
- **build-image** — builds the Docker image and pushes it to ECR tagged with
  the short commit SHA (`:<short-sha>`). Passes `RUN_NUMBER` into the image.
- **deploy** — creates/refreshes the APM Secrets, applies the manifests, then
  rolls the new image onto all three workloads.

### Manual run options (workflow_dispatch inputs)

| Input | Default | Effect |
| --- | --- | --- |
| `build_image` | `true` | Build and push a new image. Uncheck to skip building. |
| `deploy` | `true` | Deploy to EKS. Uncheck to skip deployment. |
| `fail_tests` | `false` | Force the `test` job to fail (which blocks build & deploy). Use it to see the pipeline stop on a red test. |

Behavior of the build/deploy toggles:

| `build_image` | `deploy` | Result |
| --- | --- | --- |
| ✅ | ✅ | Build a new image, then deploy it. |
| ✅ | ❌ | Build & push only, no deployment. |
| ❌ | ✅ | Deploy this commit's `:<short-sha>` image (must have been built by an earlier run). |
| ❌ | ❌ | No-op (only `prep`/`test` run). |

> On push/PR the toggles don't apply — push always builds+deploys, PRs only
> build. The toggles only take effect on manual (`workflow_dispatch`) runs.

## Secrets

The APM ingestion tokens are **not** stored in git. The deploy job creates the
K8s Secrets at deploy time from two encrypted **GitHub Actions repository
secrets**:

- `SWO_STAGING_INGESTION_TOKEN`
- `SWO_DEV_INGESTION_TOKEN`

Set them once (deploy fails with a clear error if either is missing):

```bash
gh secret set SWO_STAGING_INGESTION_TOKEN --repo <owner>/cicd-dora-github-test
gh secret set SWO_DEV_INGESTION_TOKEN    --repo <owner>/cicd-dora-github-test
```

[k8s/01-secret.yaml.example](k8s/01-secret.yaml.example) documents the Secret
shape and is only for creating them by hand on a local cluster.

## AWS / cluster targets

| Setting | Value |
| --- | --- |
| AWS account | `125229878893` |
| Region | `us-east-1` |
| ECR repository | `cicd/cicd-dora-github-test` |
| EKS cluster | `e2e-cluster` |
| Namespace | `cicd-dora-github-test` |
| OIDC deploy role | `GitHubActionsECRPush-cicd-dora-github-test` |

The pipeline authenticates to AWS with GitHub OIDC (no long-lived keys) by
assuming the role above, which grants ECR push/pull, `eks:DescribeCluster`, and
cluster access via an EKS access entry.
