# 🏴‍☠️ Going Merry - Kubernetes Homelab

A GitOps-managed Kubernetes homelab running on Talos Linux, themed after One Piece.

## 🏗️ Architecture

```plaintext
                    ┌─────────────────┐
                    │   VIP (Talos)   │
                    │  192.168.1.9    │
                    └────────┬────────┘
                             │
        ┌────────────────────┼────────────────────┐
        │                    │                    │
        ▼                    ▼                    ▼
┌───────────────┐   ┌───────────────┐   ┌───────────────┐
│     luffy     │   │     zoro      │   │     nami      │
│  192.168.1.10 │   │  192.168.1.11 │   │  192.168.1.12 │
│ control-plane │   │ control-plane │   │ control-plane │
│    worker     │   │    worker     │   │    worker     │
└───────────────┘   └───────────────┘   └───────────────┘
```

### Hardware

| Node | Hardware | Storage |
|------|----------|---------|
| luffy, zoro, nami | Beelink EQ14 (Intel N150, 16GB RAM) | 500GB NVMe (OS) + 2TB NVMe (Data) |

## 🛠️ Stack

| Component | Description |
|-----------|-------------|
| [Talos Linux](https://talos.dev) | Immutable Kubernetes OS |
| [Flux](https://fluxcd.io) | GitOps operator |
| [Cilium](https://cilium.io) | CNI with L2 LoadBalancer |
| [Longhorn](https://longhorn.io) | Distributed storage |
| [Cilium Gateway API](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/) | Ingress gateway |
| [cert-manager](https://cert-manager.io) | Certificate management |
| [SOPS](https://github.com/mozilla/sops) | Secret encryption |

## 🌐 Services

| Service | URL |
|---------|-----|
| Grafana | `https://grafana.internal` |
| Longhorn | `https://longhorn.internal` |
| AdGuard | `https://adguard.internal` |
| Homarr | `https://homarr.internal` |
| Hubble | `https://hubble.internal` |

## 📁 Repository Structure

```plaintext
├── kubernetes/
│   ├── flux/           # Flux configuration & variables
│   ├── infrastructure/ # Core cluster components
│   └── apps/           # User applications
├── talos/              # Talos Linux configuration
└── Taskfile.yaml       # Automation tasks
```

## 🚀 Quick Start

### Prerequisites

```bash
brew install siderolabs/tap/talosctl budimanjojo/tap/talhelper \
  kubectl fluxcd/tap/flux sops age yq jq go-task
```

### Commands

```bash
task --list              # Show all available tasks
task talos:status        # Cluster status
task flux:status         # Flux status
task flux:reconcile      # Force reconciliation
```

## 🔐 Secrets Management

Secrets are encrypted with SOPS + Age and stored in Git. Flux decrypts them automatically.

```bash
task sops:encrypt FILE=path/to/secret.sops.yaml
task sops:edit FILE=path/to/secret.sops.yaml
```

## 🔄 Updates

[Renovate](https://renovatebot.com) automatically creates PRs for:

- Helm chart versions
- Docker images
- Talos & Kubernetes versions
