# Changelog

All notable changes to klabctl are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-10-27

Initial release.

### Kubernetes

- Default: 1.36 (newest patch in that minor)
- Targeted minors: 1.35, 1.36, 1.37

### Added

- Multipass VMs, kubeadm bootstrap, Calico, and a host kubeconfig for multi-node labs.
- Commands: `create`, `list`, `nodes`, `shell`, `start`, `stop`, `refresh`, `delete`, and `version`.
- `--k8s-version` selects a Kubernetes minor or pins a patch when creating a cluster.
- Create flags for control-plane and worker counts and per-node CPU, memory, and disk.
- Tag push publishes a GitHub Release from this changelog. See [RELEASING.md](RELEASING.md).

[0.1.0]: https://github.com/SkaleKontrol/klabctl/releases/tag/v0.1.0
