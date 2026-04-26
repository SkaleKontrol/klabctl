#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/scripts/cluster/common.sh"
source "$SCRIPT_DIR/scripts/cluster/refresh.sh"
source "$SCRIPT_DIR/scripts/cluster/lifecycle.sh"

usage() {
  cat <<'EOF'
Usage:
  ./klabctl.sh list
  ./klabctl.sh nodes [cluster-name]
  ./klabctl.sh create <cluster-name> [--control-planes N] [--workers N] \
    [--cp-cpus N] [--cp-memory SIZE] [--cp-disk SIZE] \
    [--worker-cpus N] [--worker-memory SIZE] [--worker-disk SIZE]
  ./klabctl.sh shell <cluster-name> [node-name]
  ./klabctl.sh start <cluster-name>
  ./klabctl.sh stop <cluster-name>
  ./klabctl.sh refresh <cluster-name>
  ./klabctl.sh delete <cluster-name> [--yes] [--purge]

Commands:
  list                   List clusters created by naming convention.
  nodes [cluster-name]   List cluster nodes (or all nodes when omitted).
  create <cluster-name>  Create cluster.
  shell <cluster-name>   Open shell in a node (default: <cluster-name>-cp1).
  start <cluster-name>   Start one cluster's VMs only.
  stop <cluster-name>    Stop one cluster's VMs only.
  refresh <cluster-name> Refresh kubeconfig and hosts files for cluster.
  delete <cluster-name>  Delete one cluster's VMs only.

Options:
  --yes                Skip delete confirmation prompt.
  --purge              Run `multipass purge` after delete.

Examples:
  ./klabctl.sh list
  ./klabctl.sh nodes
  ./klabctl.sh nodes <cluster-name>
  ./klabctl.sh create <cluster-name> --control-planes 3 --workers 2
  ./klabctl.sh shell <cluster-name>
  ./klabctl.sh shell <cluster-name> <cluster-name>-worker1
  ./klabctl.sh start <cluster-name>
  ./klabctl.sh stop <cluster-name>
  ./klabctl.sh refresh <cluster-name>
  ./klabctl.sh delete <cluster-name> --yes --purge
EOF
}

main() {
  require_multipass

  local cmd="${1:-help}"
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
        echo "Tip: run './klabctl.sh nodes $cluster' to see available nodes."
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
