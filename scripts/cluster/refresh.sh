#!/usr/bin/env bash

refresh_cluster_network() {
  local cluster="$1"
  local cp1="${cluster}-cp1"
  local kubeconfig_file hosts_file cp1_ip
  local repo_root

  if ! cluster_exists "$cluster"; then
    echo "Cluster '$cluster' not found (missing ${cp1})."
    return 1
  fi

  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  kubeconfig_file="$repo_root/kubeconfig-${cluster}.yaml"
  hosts_file="$repo_root/${cluster}-hosts"
  cp1_ip="$(multipass info "$cp1" 2>/dev/null | awk '/IPv4:/{print $2; exit}')"

  if [[ -n "$cp1_ip" ]]; then
    echo "Refreshing kubeconfig (${cp1}: ${cp1_ip})..."
    multipass exec "$cp1" -- cat /home/ubuntu/.kube/config 2>/dev/null | sed "s/127.0.0.1/$cp1_ip/g" > "$kubeconfig_file"
    echo "Kubeconfig saved to $kubeconfig_file"
  fi

  {
    echo "# Cluster nodes - add to /etc/hosts: sudo tee -a /etc/hosts < $hosts_file"
    while IFS= read -r node; do
      local ip
      ip=$(multipass info "$node" 2>/dev/null | awk '/IPv4:/{print $2; exit}')
      [[ -n "$ip" ]] && echo "$ip  $node"
    done < <(existing_cluster_nodes "$cluster" | sort -V)
  } > "$hosts_file"
  echo "Cluster hosts saved to $hosts_file"
}

cmd_refresh() {
  local cluster="$1"
  validate_cluster_name "$cluster"
  refresh_cluster_network "$cluster"
}
