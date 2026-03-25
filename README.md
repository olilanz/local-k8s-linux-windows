# Developer Cluster v1 – Hybrid Windows/Linux Kubernetes (Local Laptop Setup)

## Purpose

This document defines a **local developer Kubernetes environment** that:

- Supports **both Windows and Linux workloads**
- Enables **gradual migration from Windows → Linux**
- Closely resembles **production (AKS-like) behavior**
- Avoids reliance on Docker Desktop (cost + architecture reasons)
- Is **reproducible across ~150 developers**

This setup is intended as a **long-lived developer platform**, not just a temporary lab.

---

# Architecture Overview

```

Windows 11 Host
│
├─ Hyper-V VM (Linux)
│   ├─ k0s Kubernetes control plane
│   ├─ Linux worker node
│   └─ containerd runtime
│
├─ Windows Host (acts as Kubernetes node)
│   ├─ containerd + runhcs
│   ├─ kubelet + kube-proxy
│   └─ Windows workloads
│
└─ WSL
└─ Developer tooling only (kubectl, build tools, etc.)

```

---

# Key Design Decisions

## 1. Dedicated Linux VM (Hyper-V) for Control Plane

We do **not use WSL for the Kubernetes control plane**.

### Why:
- WSL networking can reset → cluster instability
- Control plane must be **stable and long-lived**
- Hyper-V VM behaves like **real infrastructure**

### Result:
- Predictable networking
- Reproducible cluster behavior
- Matches production mental model

---

## 2. k0s + k0sctl for Cluster Bootstrap

We use:

- **k0s** for Kubernetes distribution
- **k0sctl** for provisioning

### Why:
- Single binary → simple setup
- Easy automation for 150 developers
- No dependency on kubeadm complexity
- Good fit for local clusters

### Tradeoff:
- Windows support less documented than kubeadm
- We compensate by using **SIG-Windows practices for Windows node**

---

## 3. Windows Host as Kubernetes Worker Node

The Windows machine itself joins the cluster as a node.

### Stack:

- containerd
- runhcs
- kubelet
- kube-proxy

### Why:
- Required for Windows containers in Kubernetes
- Matches real cluster behavior (AKS/EKS)
- Avoids Docker Desktop limitations

---

## 4. No Docker Desktop Dependency

Docker Desktop is intentionally removed from the architecture.

### Why:
- Cost reduction (~$15 × hundreds of users)
- Docker Desktop Kubernetes is:
  - single-node
  - non-extensible
  - not suitable for hybrid clusters
- Runtime mismatch (Kubernetes uses containerd)

### Replacement:

| Use case | Tool |
|--------|------|
| Kubernetes runtime | containerd |
| Windows container builds | Podman (optional) |
| Linux builds | inside VM / WSL |

---

## 5. Calico for Networking

We use:

- **Calico**
- **VXLAN mode**

### Why:
- Supports hybrid Linux/Windows clusters
- Works across VM ↔ host boundary
- No manual routing required
- Matches real-world setups

---

## Critical Configuration

### VXLAN mode

```

Overlay networking across nodes

```

### strictAffinity = true

Required for mixed OS clusters:

```

Prevents Linux nodes from borrowing Windows IPs

```

---

## 6. containerd Everywhere

Kubernetes runtime:

```

kubelet → containerd → runhcs (Windows) / runc (Linux)

```

### Why:
- Required since Kubernetes 1.24+
- Matches production clusters
- Supported by Calico and Windows nodes

---

## 7. WSL = Development Only

WSL is **not part of the cluster**.

### Used for:
- kubectl
- Helm
- scripts
- builds

### Not used for:
- control plane
- node runtime

---

# Networking Model

## Node IPs

```

Linux VM:     e.g. 192.168.x.x
Windows host: e.g. 192.168.x.x

```

## Pod network

```

10.244.0.0/16

```

## Flow example

Linux pod → Windows pod:

```

Pod → VXLAN → Windows node → HNS → Pod

```

Windows pod → Linux pod:

```

Pod → HNS → VXLAN → Linux node → Pod

```

---

# Hyper-V Configuration

Use:

```

External virtual switch

```

### Why:
- Stable networking
- VM reachable from host
- Required for cluster communication

Avoid:
- Default NAT switch

---

# Developer Workflow Model

Developers do **not run full system**.

They run:

```

Platform services (Kubernetes)

* selected service slice
* local service override (optional)

```

Example:

```

Kubernetes
├─ shared services
├─ service A
├─ service B

Local machine
└─ service C (debugging)

```

---

# Migration Model

Supports gradual transition:

## Stage 1
- Windows services on Windows node

## Stage 2
- New services on Linux node

## Stage 3
- Dual deployment

```

Service
├─ Windows pod
└─ Linux pod

```

## Stage 4
- Remove Windows node

---

# Why This Architecture

This setup was chosen because it:

## Matches real-world clusters

- Similar to AKS mixed node pools
- containerd-based
- Calico-supported networking

## Enables migration

- Windows and Linux workloads coexist
- Direct comparison possible

## Is reproducible

- Scriptable bootstrap
- Works on developer laptops

## Avoids known issues

- No WSL control plane instability
- No Docker Desktop limitations
- No single-node cluster constraints

## Balances simplicity and correctness

- k0s simplifies cluster setup
- SIG-Windows practices ensure Windows compatibility

---

# Known Risks

- Windows node bootstrap complexity
- Calico configuration errors
- VM ↔ host networking issues
- kube-proxy on Windows

---

# Next Steps for Implementation

1. Create Hyper-V VM
2. Install k0s + k0sctl
3. Initialize cluster
4. Install Calico (VXLAN)
5. Configure Windows node:
   - containerd
   - kubelet
   - kube-proxy
6. Join Windows node
7. Validate cross-OS networking
8. Add base services (ingress, DNS, telemetry)

---

# Goal

Provide developers with:

> A local Kubernetes cluster that behaves like production, supports hybrid workloads, and enables a multi-year migration from Windows to Linux.

---
```
