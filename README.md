# Local Kubernetes (Linux + Windows) with k0s + Calico

This repository provides a **deterministic, script-driven setup** for running a local Kubernetes cluster using:

* **k0s** (single-node control plane)
* **containerd**
* **Calico (VXLAN + strictAffinity)** for Windows compatibility
* **Windows worker node support**

The setup is designed for **repeatability, clarity, and controlled experimentation**, not for production.

---

# Architecture Overview

```text
Linux VM (Ubuntu 24.04)
  └── k0s (single-node control plane)
      └── containerd
      └── Calico (VXLAN overlay)

Windows host
  └── containerd + kubelet
      └── joins cluster as worker
```

Key design goals:

* Match production-like behavior (AKS-style cluster)
* Support **mixed OS workloads (Linux + Windows)**
* Enable **local development with real networking semantics**
* Ensure **full rebuild capability without hidden state**

---

# Key Decisions & Learnings

## 1. Networking must be correct from the start

You **cannot safely change the CNI/network model after cluster creation**.

Changing:

* IPIP → VXLAN
* IPAM behavior
* overlay mode

requires:

```text
→ full cluster rebuild
```

This is why networking is handled as a **separate, explicit step**.

---

## 2. Calico version matters (Ubuntu 24.04)

Ubuntu 24.04 requires a **newer Calico version**.

Older manifests will:

* fail silently
* hang during CRD or pod startup
* never produce a usable IPPool

This repo uses a **validated Calico manifest** compatible with:

```text
Kernel: 6.8.x
OS: Ubuntu 24.04
```

---

## 3. Windows compatibility requirements

To support Windows nodes, Calico must be configured with:

```text
ipipMode: Never
vxlanMode: Always
strictAffinity: true
```

Without this:

```text
→ Windows nodes fail to join or behave unpredictably
```

---

## 4. Determinism over convenience

All scripts are designed to be:

```text
✔ re-entrant
✔ explicit
✔ state-resetting when required
```

No hidden assumptions.

---

## 5. Cluster state lives in `/var/lib/k0s`

This is critical:

```text
/var/lib/k0s = the cluster
```

If not removed:

```text
→ previous state leaks
→ kubelet may not start
→ node may not register
```

---

## 6. Script separation (important)

Instead of one large script, the system is split into **independent stages**.

This avoids:

```text
❌ debugging everything at once
❌ hidden failures
❌ state drift
```

---

# Repository Structure

```text
config/
  k0s.yaml
  calico.yaml
  calico-ippool.yaml
  calico-ipam.yaml

scripts:
  01-prereqs.sh
  02-cluster.sh
  03-network-calico.sh
  04-smoke-nginx.sh
  05-diagnostics.sh
  99-cleanup.sh
```

---

# Script Responsibilities

## `01-prereqs.sh`

Prepares the host:

* installs containerd
* installs CNI plugins
* installs k0s

Does **not** touch cluster state.

---

## `02-cluster.sh`

Creates a **clean k0s cluster**:

* wipes previous cluster state
* installs k0s controller (`--single`)
* starts cluster
* waits for node registration

---

## `03-network-calico.sh`

Installs networking:

* applies Calico manifest
* applies IPPool (VXLAN)
* applies IPAM (strictAffinity)
* waits for readiness

---

## `04-smoke-nginx.sh`

Validates cluster functionality:

* deploys nginx
* exposes service
* verifies in-cluster connectivity

---

## `05-diagnostics.sh`

Debug tool:

* nodes
* pods
* services
* Calico state
* kubelet process
* container runtime
* API health

Use this at any time.

---

## `99-cleanup.sh`

Fully destructive reset:

* stops k0s
* removes cluster state
* clears CNI + networking
* resets iptables
* restarts containerd

Guarantees:

```text
→ clean slate
```

---

# Usage Workflow

## Clean rebuild (recommended)

```bash
./99-cleanup.sh
sudo reboot

./01-prereqs.sh
./02-cluster.sh
./03-network-calico.sh
./04-smoke-nginx.sh
```

---

## Diagnostics

```bash
./05-diagnostics.sh
```

---

# Expected State

After successful setup:

```text
Nodes:
  Linux control-plane → Ready
  Windows worker     → Ready (after join)

Calico:
  calico-node        → Running
  VXLAN              → Active

Workloads:
  nginx              → reachable via cluster IP
```

---

# Troubleshooting Principles

## If cluster fails (`02-cluster.sh`)

Check:

```bash
ps aux | grep kubelet
```

If missing:

```text
→ cluster state was not clean
```

---

## If Calico fails (`03-network-calico.sh`)

Check:

```bash
kubectl get crd | grep ippool
kubectl get pods -n kube-system
```

Common cause:

```text
→ incompatible Calico version
```

---

## If pods don’t start

Check:

```bash
./05-diagnostics.sh
```

Focus on:

* containerd
* CNI directories
* node readiness

---

# Scope & Intent

This setup is intended for:

* local Kubernetes experimentation
* hybrid Linux/Windows validation
* architecture prototyping

It is **not** intended for production use.

---

# Final Note

The most important invariant in this setup:

```text
Correct networking must be defined before cluster creation.
```

Everything else is recoverable.
Networking is not.
