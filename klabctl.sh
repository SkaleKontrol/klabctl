#!/usr/bin/env bash
set -euo pipefail

# Resolve symlinks so /usr/bin/klabctl can point at /usr/lib/klabctl/klabctl.sh.
_src="${BASH_SOURCE[0]}"
while [[ -L "$_src" ]]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  [[ "$_src" != /* ]] && _src="$_dir/$_src"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
unset _src _dir
source "$SCRIPT_DIR/scripts/cluster/common.sh"
source "$SCRIPT_DIR/scripts/cluster/refresh.sh"
source "$SCRIPT_DIR/scripts/cluster/lifecycle.sh"

usage() {
  cat <<'EOF'
Usage:
  klabctl list
  klabctl nodes [cluster-name]
  klabctl create <cluster-name> [--control-planes N] [--workers N] \
    [--k8s-version VERSION] \
    [--cp-cpus N] [--cp-memory SIZE] [--cp-disk SIZE] \
    [--worker-cpus N] [--worker-memory SIZE] [--worker-disk SIZE]
  klabctl shell <cluster-name> [node-name]
  klabctl start <cluster-name>
  klabctl stop <cluster-name>
  klabctl refresh <cluster-name>
  klabctl delete <cluster-name> [--yes] [--purge]
  klabctl version

Commands:
  list                   List clusters created by naming convention.
  nodes [cluster-name]   List cluster nodes (or all nodes when omitted).
  create <cluster-name>  Create cluster (default Kubernetes v1.36).
  shell <cluster-name>   Open shell in a node (default: <cluster-name>-cp1).
  start <cluster-name>   Start one cluster's VMs only.
  stop <cluster-name>    Stop one cluster's VMs only.
  refresh <cluster-name> Refresh kubeconfig and hosts files for cluster.
  delete <cluster-name>  Delete one cluster's VMs only.
  version                Print the klabctl version.

Options:
  --k8s-version VER    Kubernetes minor (1.36) or patch (1.36.5). Default: 1.36.
                       Targeted minors: 1.35, 1.36, 1.37. A leading v is optional.
  --yes                Skip delete confirmation prompt.
  --purge              Run `multipass purge` after delete.

Examples:
  klabctl list
  klabctl nodes
  klabctl nodes <cluster-name>
  klabctl create <cluster-name> --control-planes 3 --workers 2
  klabctl create <cluster-name> --k8s-version 1.35
  klabctl create <cluster-name> --k8s-version 1.36.5
  klabctl shell <cluster-name>
  klabctl shell <cluster-name> <cluster-name>-worker1
  klabctl start <cluster-name>
  klabctl stop <cluster-name>
  klabctl refresh <cluster-name>
  klabctl delete <cluster-name> --yes --purge
  klabctl version
EOF
}

klabctl_version() {
  local version_file="$SCRIPT_DIR/VERSION"
  if [[ ! -f "$version_file" ]]; then
    echo "klabctl version file missing: $version_file" >&2
    exit 1
  fi
  local version
  version="$(tr -d '[:space:]' < "$version_file")"
  if [[ -z "$version" ]]; then
    echo "klabctl version file is empty: $version_file" >&2
    exit 1
  fi
  echo "klabctl $version"
}

main() {
  local cmd="${1:-help}"
  case "$cmd" in
    version)
      klabctl_version
      return
      ;;
  esac

  require_multipass

  case "$cmd" in
    list)
      cmd_list
      ;;
    nodes)
      local cluster="${2:-}"
      if [[ -n "$cluster" ]]; then
        validate_cluster_name "$cluster"
        multipass list --format csv 2>/dev/null | awk -F, -v c="$cluster" '
          NR==1 { next }
          $1 ~ ("^" c "-(cp|worker)[0-9]+$") { print $0 }
        ' | {
          read -r first || true
          if [[ -z "${first:-}" ]]; then
            echo "No VMs found for cluster '$cluster'."
          else
            printf "Name,State,IPv4,Image\n%s\n" "$first"
            cat
          fi
        }
      else
        multipass list
      fi
      ;;
    create)
      local cluster="${2:-}"
      [[ -z "$cluster" ]] && { usage; exit 1; }
      shift
      "$SCRIPT_DIR/scripts/cluster/create.sh" "$@"
      ;;
    shell)
      local cluster="${2:-}"
      local node="${3:-}"
      [[ -z "$cluster" ]] && { usage; exit 1; }
      validate_cluster_name "$cluster"
      if [[ -z "$node" ]]; then
        node="${cluster}-cp1"
      fi
      if [[ ! "$node" =~ ^${cluster}-(cp|worker)[0-9]+$ ]]; then
        echo "Node '$node' does not belong to cluster '$cluster'."
        echo "Expected format: ${cluster}-cpN or ${cluster}-workerN"
        exit 1
      fi
      if ! multipass info "$node" >/dev/null 2>&1; then
        echo "Node '$node' not found."
        echo "Tip: run 'klabctl nodes $cluster' to see available nodes."
        exit 1
      fi
      multipass shell "$node"
      ;;
    start)
      local cluster="${2:-}"
      [[ -z "$cluster" ]] && { usage; exit 1; }
      cmd_start "$cluster"
      ;;
    stop)
      local cluster="${2:-}"
      [[ -z "$cluster" ]] && { usage; exit 1; }
      cmd_stop "$cluster"
      ;;
    refresh)
      local cluster="${2:-}"
      [[ -z "$cluster" ]] && { usage; exit 1; }
      cmd_refresh "$cluster"
      ;;
    delete)
      local cluster="${2:-}"
      [[ -z "$cluster" ]] && { usage; exit 1; }
      local auto_yes="false"
      local do_purge="false"
      shift 2
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --yes) auto_yes="true" ;;
          --purge) do_purge="true" ;;
          *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
        esac
        shift
      done
      cmd_delete "$cluster" "$auto_yes" "$do_purge"
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      echo "Unknown command: $cmd"
      usage
      exit 1
      ;;
  esac
}

main "$@"
