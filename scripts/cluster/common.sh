#!/usr/bin/env bash

require_multipass() {
  if ! command -v multipass >/dev/null 2>&1; then
    echo "multipass is not installed. Run: sudo snap install multipass"
    exit 1
  fi
}

validate_cluster_name() {
  local cluster="$1"
  if [[ ! "$cluster" =~ ^[a-z0-9-]+$ ]]; then
    echo "Invalid cluster name '$cluster'. Use lowercase letters, numbers, and hyphens only."
    exit 1
  fi
}

all_instance_names() {
  multipass list --format csv 2>/dev/null | awk -F, 'NR>1 {print $1}'
}

discover_clusters() {
  all_instance_names | awk '
    {
      n = split($0, parts, "-")
      if (n < 2) next
      suffix = parts[n]
      if (suffix !~ /^(cp|worker)[0-9]+$/) next
      cluster = parts[1]
      for (i = 2; i < n; i++) cluster = cluster "-" parts[i]
      if (cluster ~ /^[a-z0-9-]+$/) print cluster
    }
  ' | sort -u
}

existing_cluster_nodes() {
  local cluster="$1"
  all_instance_names | awk -v c="$cluster" '$0 ~ ("^" c "-(cp|worker)[0-9]+$")'
}

count_running_for_cluster() {
  local cluster="$1"
  multipass list --format csv 2>/dev/null | awk -F, -v c="$cluster" '
    NR>1 && $1 ~ ("^" c "-(cp|worker)[0-9]+$") && $2 == "Running" { n++ }
    END { print n+0 }
  '
}

count_total_for_cluster() {
  local cluster="$1"
  all_instance_names | awk -v c="$cluster" '$0 ~ ("^" c "-(cp|worker)[0-9]+$") { n++ } END { print n+0 }'
}

cluster_exists() {
  local cluster="$1"
  local cp1="${cluster}-cp1"
  all_instance_names | awk -v n="$cp1" '$0 == n {found=1} END {exit !found}'
}
