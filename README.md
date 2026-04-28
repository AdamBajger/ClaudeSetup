# claude-cli-cloud-run

Pre-built containerized development environment for [Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview).

> **Warning:** Rootless SSH access is planned but currently untested and likely non-functional. The quickstart steps below deploy the environment without SSH.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) & [Docker Compose](https://docs.docker.com/compose/) (for local deployment)
- [kubectl](https://kubernetes.io/docs/tasks/tools/) & [Helm](https://helm.sh/docs/intro/install/) (for Kubernetes deployment)
- A Kubernetes cluster (for Helm deployment)

## Quickstart

### 1. Run locally with Docker Compose

```bash
# 1. Copy and edit the environment file
cp .env.example .env
# Edit .env and set AUTHORIZED_KEYS and optional GH_TOKEN

# 2. Start the container
docker compose up -d --build
```

Configuration details are in [`.env.example`](.env.example) and [`docker-compose.yml`](docker-compose.yml).

### 2. Install in Kubernetes with Helm

```bash
# 1. Copy and edit the values file
cp k8s/helm/claude-cli/values.example.yaml k8s/helm/claude-cli/values.yaml
# Edit values.yaml and set auth.authorizedKeys and other options

# 2. Install the chart
helm install claude-cli k8s/helm/claude-cli -f k8s/helm/claude-cli/values.yaml
```

Configuration details are in [`k8s/helm/claude-cli/values.example.yaml`](k8s/helm/claude-cli/values.example.yaml).

## Documentation

- [Claude Code documentation](https://docs.anthropic.com/en/docs/claude-code/overview)
- [Docker Compose reference](https://docs.docker.com/compose/)
- [Helm documentation](https://helm.sh/docs/)
- [kubectl reference](https://kubernetes.io/docs/reference/kubectl/)

## Configuration Files

| File | Purpose |
|------|---------|
| [`.env.example`](.env.example) | Docker Compose environment variables |
| [`docker-compose.yml`](docker-compose.yml) | Local container orchestration |
| [`k8s/helm/claude-cli/values.example.yaml`](k8s/helm/claude-cli/values.example.yaml) | Helm chart configuration |

All configuration files contain inline comments explaining available options.
