#!/usr/bin/env bash

cmd_list() {
  local clusters
  clusters="$(discover_clusters || true)"
  if [[ -z "${clusters:-}" ]]; then
    echo "No clusters found."
    return
  fi

  printf "%-20s %-10s %-s\n" "CLUSTER" "RUNNING" "NODES"
  printf "%-20s %-10s %-s\n" "-------" "-------" "-----"
  while IFS= read -r c; do
    [[ -z "$c" ]] && continue
    printf "%-20s %-10s %-s\n" "$c" "$(count_running_for_cluster "$c")/$(count_total_for_cluster "$c")" "$(count_total_for_cluster "$c")"
  done <<<"$clusters"
}

cmd_start() {
  local cluster="$1"
  validate_cluster_name "$cluster"

  local nodes
  nodes="$(existing_cluster_nodes "$cluster")"
  if [[ -z "${nodes:-}" ]]; then
    echo "No VMs found for cluster '$cluster'."
    return
  fi

  mapfile -t node_arr < <(printf "%s\n" "$nodes")
  multipass start "${node_arr[@]}"
  refresh_cluster_network "$cluster" || true
  echo "Started cluster '$cluster'."
}

cmd_stop() {
  local cluster="$1"
  validate_cluster_name "$cluster"

  local nodes
  nodes="$(existing_cluster_nodes "$cluster")"
  if [[ -z "${nodes:-}" ]]; then
    echo "No VMs found for cluster '$cluster'."
    return
  fi

  mapfile -t node_arr < <(printf "%s\n" "$nodes")
  multipass stop "${node_arr[@]}"
  echo "Stopped cluster '$cluster'."
}

cmd_delete() {
  local cluster="$1"
  local auto_yes="${2:-false}"
  local do_purge="${3:-false}"
  local repo_root kubeconfig_file hosts_file
  validate_cluster_name "$cluster"
  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  kubeconfig_file="$repo_root/kubeconfig-${cluster}.yaml"
  hosts_file="$repo_root/${cluster}-hosts"

  local nodes
  nodes="$(existing_cluster_nodes "$cluster")"
  if [[ -z "${nodes:-}" ]]; then
    echo "No VMs found for cluster '$cluster'."
    return
  fi

  echo "Will delete cluster '$cluster' VMs:"
  echo "$nodes" | sed 's/^/  - /'

  if [[ "$auto_yes" != "true" ]]; then
    read -r -p "Continue? (y/N): " ans
    if [[ ! "$ans" =~ ^[yY]$ ]]; then
      echo "Aborted."
      return
    fi
  fi

  mapfile -t node_arr < <(printf "%s\n" "$nodes")
  multipass delete "${node_arr[@]}"
  echo "Deleted VMs for cluster '$cluster'."

  if command -v kubectl >/dev/null 2>&1 && [[ -f "$HOME/.kube/config" ]]; then
    kubectl config delete-context "$cluster" >/dev/null 2>&1 || true
    kubectl config delete-cluster "$cluster" >/dev/null 2>&1 || true
    kubectl config delete-user "${cluster}-admin" >/dev/null 2>&1 || \
      kubectl config unset "users.${cluster}-admin" >/dev/null 2>&1 || true
    echo "Removed kubeconfig entries for cluster '$cluster' from ~/.kube/config (if present)."
  fi

  if [[ -f "$kubeconfig_file" ]]; then
    rm -f "$kubeconfig_file"
    echo "Removed local kubeconfig file: $kubeconfig_file"
  fi

  if [[ -f "$hosts_file" ]]; then
    rm -f "$hosts_file"
    echo "Removed hosts file: $hosts_file"
  fi

  if [[ "$do_purge" == "true" ]]; then
    multipass purge
    echo "Purged deleted instances."
  else
    echo "Tip: run 'multipass purge' later to reclaim space from deleted instances."
  fi
}
