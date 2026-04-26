#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEFAULT_CLUSTER_NAME="k8s"
DEFAULT_CP_COUNT=1
DEFAULT_WORKER_COUNT=1
CLUSTER_NAME="$DEFAULT_CLUSTER_NAME"
CP_COUNT="$DEFAULT_CP_COUNT"
WORKER_COUNT="$DEFAULT_WORKER_COUNT"
NODES=()
CP_NODES=()
WORKER_NODES=()
CP1=""
K8S_VERSION="1.36"
# Multipass catalog: bare "26.04" can hit flaky simplestreams ("Remote \"\" is unknown"); prefer explicit image.
UBUNTU_RELEASE="${UBUNTU_RELEASE:-26.04}"
MULTIPASS_IMAGE="${MULTIPASS_IMAGE:-}"
MULTIPASS_LAUNCH_RETRIES="${MULTIPASS_LAUNCH_RETRIES:-5}"
HOST_KUBECONFIG=""
# Recommended default lab sizing (users can override with flags below)
CP_VCPU=2
CP_RAM="4G"
CP_DISK="10G"
WORKER_VCPU=2
WORKER_RAM="4G"
WORKER_DISK="10G"
CONTROL_PLANE_CERT_KEY=""
CONTROL_PLANE_JOIN_CMD=""
WORKER_JOIN_CMD=""

log() { echo "[$(date +%H:%M:%S)] $*"; }

size_to_mb() {
  local v="${1^^}"
  if [[ "$v" =~ ^[0-9]+$ ]]; then
    echo "$v"
    return 0
  fi
  if [[ "$v" =~ ^([0-9]+)(M|MB)$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$v" =~ ^([0-9]+)(G|GB)$ ]]; then
    echo $(( BASH_REMATCH[1] * 1024 ))
    return 0
  fi
  return 1
}

validate_size_arg() {
  local label="$1" value="$2"
  if ! [[ "$value" =~ ^[0-9]+([MmGg][Bb]?)?$ ]]; then
    echo "Invalid $label '$value'. Use forms like 1700M, 2G, 4096MB."
    exit 1
  fi
}

# Resolve image alias for multipass launch (avoids empty-remote failures on some versions).
multipass_image() {
  if [[ -n "$MULTIPASS_IMAGE" ]]; then
    echo "$MULTIPASS_IMAGE"
    return
  fi
  case "$UBUNTU_RELEASE" in
    26.04) echo "daily:26.04" ;;
    *) echo "$UBUNTU_RELEASE" ;;
  esac
}

run_parallel_for_nodes() {
  local label="$1"
  shift
  local action="$1"
  shift
  local nodes=("$@")
  local pids=()
  local pid_nodes=()
  local failed=0

  for node in "${nodes[@]}"; do
    (
      "$action" "$node"
    ) &
    pids+=("$!")
    pid_nodes+=("$node")
  done

  for i in "${!pids[@]}"; do
    if ! wait "${pids[$i]}"; then
      log "ERROR: ${label} failed for ${pid_nodes[$i]}"
      failed=1
    fi
  done

  if (( failed )); then
    log "ERROR: One or more ${label} tasks failed."
    exit 1
  fi
}

usage() {
  cat <<EOF
Usage:
  ./klabctl.sh create <cluster-name> [--control-planes N] [--workers N] \
    [--cp-cpus N] [--cp-memory SIZE] [--cp-disk SIZE] \
    [--worker-cpus N] [--worker-memory SIZE] [--worker-disk SIZE]

Defaults:
  cluster-name: ${DEFAULT_CLUSTER_NAME}
  control-planes: ${DEFAULT_CP_COUNT}
  workers: ${DEFAULT_WORKER_COUNT}
  cp-cpus: ${CP_VCPU}, cp-memory: ${CP_RAM}, cp-disk: ${CP_DISK}
  worker-cpus: ${WORKER_VCPU}, worker-memory: ${WORKER_RAM}, worker-disk: ${WORKER_DISK}

Examples:
  ./klabctl.sh create k8s
  ./klabctl.sh create <cluster-name>
  ./klabctl.sh create <cluster-name> --control-planes 3 --workers 2
  ./klabctl.sh create <cluster-name> --cp-cpus 4 --cp-memory 4G --cp-disk 30G --worker-cpus 2 --worker-memory 4G --worker-disk 30G
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --control-planes)
        CP_COUNT="${2:-}"
        [[ -z "$CP_COUNT" ]] && { echo "Missing value for --control-planes"; exit 1; }
        shift 2
        ;;
      --workers)
        WORKER_COUNT="${2:-}"
        [[ -z "$WORKER_COUNT" ]] && { echo "Missing value for --workers"; exit 1; }
        shift 2
        ;;
      --cp-cpus)
        CP_VCPU="${2:-}"
        [[ -z "$CP_VCPU" ]] && { echo "Missing value for --cp-cpus"; exit 1; }
        shift 2
        ;;
      --cp-memory)
        CP_RAM="${2:-}"
        [[ -z "$CP_RAM" ]] && { echo "Missing value for --cp-memory"; exit 1; }
        shift 2
        ;;
      --cp-disk)
        CP_DISK="${2:-}"
        [[ -z "$CP_DISK" ]] && { echo "Missing value for --cp-disk"; exit 1; }
        shift 2
        ;;
      --worker-cpus)
        WORKER_VCPU="${2:-}"
        [[ -z "$WORKER_VCPU" ]] && { echo "Missing value for --worker-cpus"; exit 1; }
        shift 2
        ;;
      --worker-memory)
        WORKER_RAM="${2:-}"
        [[ -z "$WORKER_RAM" ]] && { echo "Missing value for --worker-memory"; exit 1; }
        shift 2
        ;;
      --worker-disk)
        WORKER_DISK="${2:-}"
        [[ -z "$WORKER_DISK" ]] && { echo "Missing value for --worker-disk"; exit 1; }
        shift 2
        ;;
      --*)
        echo "Unknown option: $1"
        usage
        exit 1
        ;;
      *)
        if [[ "$CLUSTER_NAME" != "$DEFAULT_CLUSTER_NAME" ]]; then
          echo "Unexpected argument: $1"
          usage
          exit 1
        fi
        CLUSTER_NAME="$1"
        shift
        ;;
    esac
  done
}

init_nodes() {
  CP_NODES=()
  WORKER_NODES=()
  NODES=()

  for i in $(seq 1 "$CP_COUNT"); do
    CP_NODES+=("${CLUSTER_NAME}-cp${i}")
  done
  for i in $(seq 1 "$WORKER_COUNT"); do
    WORKER_NODES+=("${CLUSTER_NAME}-worker${i}")
  done
  NODES=("${CP_NODES[@]}" "${WORKER_NODES[@]}")
  CP1="${CP_NODES[0]}"
  HOST_KUBECONFIG="$REPO_ROOT/kubeconfig-${CLUSTER_NAME}.yaml"
}

confirm_resource_requirements() {
  local total_vcpu total_ram_mb total_ram_gb overhead_ram_gb
  total_vcpu=$(( CP_COUNT * CP_VCPU + WORKER_COUNT * WORKER_VCPU ))
  total_ram_mb=$(( CP_COUNT * $(size_to_mb "$CP_RAM") + WORKER_COUNT * $(size_to_mb "$WORKER_RAM") ))
  total_ram_gb=$(( (total_ram_mb + 1023) / 1024 ))
  overhead_ram_gb=2

  echo
  echo "Cluster plan:"
  echo "  Name: $CLUSTER_NAME"
  echo "  Control-plane nodes: $CP_COUNT (${CP_VCPU} vCPU, ${CP_RAM} RAM, ${CP_DISK} disk each)"
  echo "  Worker nodes:        $WORKER_COUNT (${WORKER_VCPU} vCPU, ${WORKER_RAM} RAM, ${WORKER_DISK} disk each)"
  echo
  echo "Estimated resources:"
  echo "  Total vCPU: $total_vcpu"
  echo "  Total RAM:  ${total_ram_gb} GB (+~${overhead_ram_gb} GB host overhead)"
  echo

  read -r -p "Proceed with cluster creation? (y/N): " ans
  if [[ ! "$ans" =~ ^[yY]$ ]]; then
    echo "Aborted."
    exit 0
  fi
}

get_node_ip() {
  multipass info "$1" 2>/dev/null | awk '/IPv4:/{print $2; exit}'
}

# --- Step 1: Create VMs ---
create_vms() {
  log "Creating VMs..."
  # Keep VM launch sequential; parallel launch can corrupt qcow images with Multipass/QEMU.
  for node in "${CP_NODES[@]}"; do
    launch_cp_vm "$node"
  done
  for node in "${WORKER_NODES[@]}"; do
    launch_worker_vm "$node"
  done
  log "VMs created. Waiting for them to be ready..."
  sleep 15
}

write_cloud_init_common() {
  local f="$1"
  cat >"$f" <<'CIEOF'
#cloud-config
package_update: true
packages: [curl, apt-transport-https, ca-certificates, gnupg, conntrack]
CIEOF
}

# Multipass snap: no host /tmp; home interface also blocks dotfiles under ~ (see canonical/multipass#1672).
mktemp_cloud_init_file() {
  mktemp "${HOME:?}/multipass-k8s-lab-ci-XXXXXX.yaml"
}

multipass_node_state() {
  multipass info "$1" 2>/dev/null | awk '/^State:/{sub(/^State:[ \t]+/, ""); print; exit}'
}

# First launch can exit non-zero with "is being prepared" while the instance is still coming up; do not
# immediately re-launch the same name (that amplifies the error). Wait for Running instead.
multipass_wait_running() {
  local node="$1"
  local waited=0 limit=360 step=5
  local state=""
  while (( waited < limit )); do
    if ! multipass info "$node" &>/dev/null; then
      return 1
    fi
    state="$(multipass_node_state "$node")"
    case "$state" in
      Running) return 0 ;;
      Stopped|Suspended)
        multipass start "$node" &>/dev/null || true
        ;;
    esac
    log "Waiting for $node (state: ${state:-?}) ${waited}s / ${limit}s..."
    sleep "$step"
    waited=$(( waited + step ))
  done
  return 1
}

# Transient simplestreams errors (e.g. Remote "" is unknown): retry multipass launch.
multipass_launch_once() {
  local node="$1" cpus="$2" mem="$3" disk="$4" img="$5" ci_file="$6"
  local attempt=1 max="$MULTIPASS_LAUNCH_RETRIES" delay=3
  while (( attempt <= max )); do
    if multipass launch -n "$node" -c "$cpus" -m "$mem" -d "$disk" "$img" --cloud-init "$ci_file"; then
      return 0
    fi
    # "being prepared" can fail the CLI before `info` works; poll briefly before re-launching same name.
    local poll=0
    while (( poll < 45 )) && ! multipass info "$node" &>/dev/null; do
      sleep 2
      poll=$(( poll + 2 ))
    done
    if multipass info "$node" &>/dev/null; then
      log "Launch returned error but $node exists; waiting for Running (avoid duplicate launch)..."
      if multipass_wait_running "$node"; then
        return 0
      fi
      log "Removing stuck instance $node before retry..."
      multipass delete -p "$node" 2>/dev/null || true
    fi
    if (( attempt < max )); then
      log "multipass launch failed for $node (attempt $attempt/$max), retrying in ${delay}s..."
      sleep "$delay"
      delay=$(( delay * 2 ))
      (( delay > 30 )) && delay=30
    fi
    attempt=$(( attempt + 1 ))
  done
  return 1
}

launch_cp_vm() {
  local node="$1"
  local img ci_file
  img="$(multipass_image)"
  ci_file="$(mktemp_cloud_init_file)"
  write_cloud_init_common "$ci_file"
  multipass_launch_once "$node" "$CP_VCPU" "$CP_RAM" "$CP_DISK" "$img" "$ci_file"
  rm -f "$ci_file"
}

launch_worker_vm() {
  local node="$1"
  local img ci_file
  img="$(multipass_image)"
  ci_file="$(mktemp_cloud_init_file)"
  write_cloud_init_common "$ci_file"
  multipass_launch_once "$node" "$WORKER_VCPU" "$WORKER_RAM" "$WORKER_DISK" "$img" "$ci_file"
  rm -f "$ci_file"
}

# --- Step 2: Install k8s components on all nodes ---
install_k8s_node() {
  local node=$1
  log "Installing containerd + kubeadm on $node..."
  multipass exec "$node" -- sudo env K8S_VERSION="$K8S_VERSION" bash -s << 'K8S_INSTALL'
set -e
# Preflight: ip_forward (conntrack installed via cloud-init)
echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-kubernetes.conf
sudo sysctl --system
# Containerd (no curl|gpg pipe: gpg may try /dev/tty under multipass exec; curl then fails with "Failed writing body")
DOCKER_KEY_TMP="$(mktemp)"
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$DOCKER_KEY_TMP"
sudo gpg --dearmor --batch --yes --no-tty -o /usr/share/keyrings/docker-archive-keyring.gpg "$DOCKER_KEY_TMP"
rm -f "$DOCKER_KEY_TMP"
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update -qq
sudo apt-get install -y containerd.io conntrack
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo sed -i 's/disabled_plugins = \["cri"\]/disabled_plugins = []/' /etc/containerd/config.toml
sudo systemctl enable --now containerd
sudo systemctl restart containerd

# K8s
# Some environments currently fail TLS validation on pkgs.k8s.io; fall back to the CDN URL.
K8S_KEY_URL_PRIMARY="https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key"
K8S_REPO_PRIMARY="https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/"
K8S_KEY_URL_FALLBACK="https://prod-cdn.packages.k8s.io/repositories/isv:/kubernetes:/core:/stable:/v${K8S_VERSION}/deb/Release.key"
K8S_REPO_FALLBACK="https://prod-cdn.packages.k8s.io/repositories/isv:/kubernetes:/core:/stable:/v${K8S_VERSION}/deb/"
K8S_KEY_TMP="$(mktemp)"

if curl -fsSL "$K8S_KEY_URL_PRIMARY" -o "$K8S_KEY_TMP" && sudo gpg --dearmor --batch --yes --no-tty -o /usr/share/keyrings/kubernetes-apt-keyring.gpg "$K8S_KEY_TMP"; then
  echo "deb [signed-by=/usr/share/keyrings/kubernetes-apt-keyring.gpg] ${K8S_REPO_PRIMARY} /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
else
  echo "WARN: Failed to fetch Kubernetes key from pkgs.k8s.io; using CDN fallback." >&2
  rm -f "$K8S_KEY_TMP"
  curl -fsSL "$K8S_KEY_URL_FALLBACK" -o "$K8S_KEY_TMP"
  sudo gpg --dearmor --batch --yes --no-tty -o /usr/share/keyrings/kubernetes-apt-keyring.gpg "$K8S_KEY_TMP"
  echo "deb [signed-by=/usr/share/keyrings/kubernetes-apt-keyring.gpg] ${K8S_REPO_FALLBACK} /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
fi
rm -f "$K8S_KEY_TMP"
sudo apt-get update -qq
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
K8S_INSTALL
}

# --- Step 3: Init control plane on cp1 ---
init_control_plane() {
  log "Initializing control plane on $CP1..."
  local cp1_ip
  cp1_ip=$(get_node_ip "$CP1")
  [[ -z "$cp1_ip" ]] && { log "ERROR: Could not get $CP1 IP"; exit 1; }
  log "$CP1 IP: $cp1_ip"
  multipass exec "$CP1" -- sudo kubeadm init \
    --control-plane-endpoint "$cp1_ip:6443" \
    --pod-network-cidr 192.168.0.0/16 \
    --apiserver-advertise-address "$cp1_ip" \
    --upload-certs
}

# --- Step 4: Configure kubeconfig on cp1 ---
configure_kubeconfig() {
  log "Configuring kubeconfig on $CP1..."
  multipass exec "$CP1" -- bash -c 'mkdir -p $HOME/.kube && sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config && sudo chown $(id -u):$(id -g) $HOME/.kube/config'
}

# --- Step 5: Install Calico CNI ---
install_cni() {
  log "Installing Calico CNI..."
  multipass exec "$CP1" -- kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.1/manifests/calico.yaml
  log "Waiting for CNI to be ready..."
  sleep 30
  multipass exec "$CP1" -- kubectl wait --for=condition=Ready "nodes/$CP1" --timeout=120s 2>/dev/null || true
  sleep 5
}

# --- Step 6: Get join commands and join other nodes ---
join_nodes() {
  log "Getting join commands..."
  local cert_key control_plane_join worker_join
  cert_key=$(multipass exec "$CP1" -- sudo kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1)
  control_plane_join=$(multipass exec "$CP1" -- kubeadm token create --print-join-command 2>/dev/null)
  worker_join=$(multipass exec "$CP1" -- kubeadm token create --print-join-command 2>/dev/null)
  [[ -z "$cert_key" ]] && { log "ERROR: Failed to get certificate key"; exit 1; }
  [[ -z "$control_plane_join" || -z "$worker_join" ]] && { log "ERROR: Failed to get join commands"; exit 1; }
  CONTROL_PLANE_CERT_KEY="$cert_key"
  CONTROL_PLANE_JOIN_CMD="$control_plane_join"
  WORKER_JOIN_CMD="$worker_join"

  # Join additional control-plane nodes in parallel.
  local extra_cp_nodes=()
  for node in "${CP_NODES[@]}"; do
    [[ "$node" == "$CP1" ]] && continue
    extra_cp_nodes+=("$node")
  done
  if (( ${#extra_cp_nodes[@]} > 0 )); then
    run_parallel_for_nodes "control-plane join" join_control_plane_node "${extra_cp_nodes[@]}"
  fi

  # Join workers in parallel.
  run_parallel_for_nodes "worker join" join_worker_node "${WORKER_NODES[@]}"
}

join_control_plane_node() {
  local node="$1"
  log "Joining $node as control-plane..."
  local node_ip
  node_ip=$(get_node_ip "$node")
  multipass exec "$node" -- sudo bash -c "mkdir -p /etc/kubernetes/pki/etcd && $CONTROL_PLANE_JOIN_CMD --control-plane --certificate-key $CONTROL_PLANE_CERT_KEY --apiserver-advertise-address $node_ip"
}

join_worker_node() {
  local node="$1"
  log "Joining $node as worker..."
  multipass exec "$node" -- sudo bash -c "$WORKER_JOIN_CMD"
}

# --- Step 7: Export kubeconfig for host ---
export_kubeconfig() {
  log "Exporting kubeconfig..."
  local cp1_ip
  cp1_ip=$(get_node_ip "$CP1")
  multipass exec "$CP1" -- cat /home/ubuntu/.kube/config | sed "s/127.0.0.1/$cp1_ip/g" > "$HOST_KUBECONFIG"
  log "Kubeconfig saved to $HOST_KUBECONFIG"
}

configure_host_kubeconfig() {
  if ! command -v kubectl &>/dev/null; then
    log "kubectl not found on host; skipping ~/.kube/config context setup."
    log "Manual usage: KUBECONFIG=$HOST_KUBECONFIG kubectl get nodes"
    return
  fi

  log "Configuring ~/.kube/config context '$CLUSTER_NAME'..."
  mkdir -p "$HOME/.kube"

  local server ca_data client_cert_data client_key_data tmpdir
  server="$(kubectl --kubeconfig "$HOST_KUBECONFIG" config view --raw -o jsonpath='{.clusters[0].cluster.server}')"
  ca_data="$(kubectl --kubeconfig "$HOST_KUBECONFIG" config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
  client_cert_data="$(kubectl --kubeconfig "$HOST_KUBECONFIG" config view --raw -o jsonpath='{.users[0].user.client-certificate-data}')"
  client_key_data="$(kubectl --kubeconfig "$HOST_KUBECONFIG" config view --raw -o jsonpath='{.users[0].user.client-key-data}')"
  tmpdir="$(mktemp -d)"

  printf '%s' "$ca_data" | base64 -d > "$tmpdir/ca.crt"
  printf '%s' "$client_cert_data" | base64 -d > "$tmpdir/client.crt"
  printf '%s' "$client_key_data" | base64 -d > "$tmpdir/client.key"

  KUBECONFIG="$HOME/.kube/config" kubectl config set-cluster "$CLUSTER_NAME" \
    --server="$server" \
    --certificate-authority="$tmpdir/ca.crt" \
    --embed-certs=true >/dev/null
  KUBECONFIG="$HOME/.kube/config" kubectl config set-credentials "${CLUSTER_NAME}-admin" \
    --client-certificate="$tmpdir/client.crt" \
    --client-key="$tmpdir/client.key" \
    --embed-certs=true >/dev/null
  KUBECONFIG="$HOME/.kube/config" kubectl config set-context "$CLUSTER_NAME" \
    --cluster="$CLUSTER_NAME" \
    --user="${CLUSTER_NAME}-admin" >/dev/null
  KUBECONFIG="$HOME/.kube/config" kubectl config use-context "$CLUSTER_NAME" >/dev/null
  rm -rf "$tmpdir"
  log "Host kubeconfig updated. Active context: $CLUSTER_NAME"
}

# --- Main ---
main() {
  parse_args "$@"

  if [[ ! "$CLUSTER_NAME" =~ ^[a-z0-9-]+$ ]]; then
    echo "Invalid cluster name '$CLUSTER_NAME'. Use lowercase letters, numbers, and hyphens only."
    exit 1
  fi
  if [[ ! "$CP_COUNT" =~ ^[0-9]+$ ]] || (( CP_COUNT < 1 )); then
    echo "Invalid control-plane count '$CP_COUNT'. Must be an integer >= 1."
    exit 1
  fi
  if [[ ! "$WORKER_COUNT" =~ ^[0-9]+$ ]] || (( WORKER_COUNT < 1 )); then
    echo "Invalid worker count '$WORKER_COUNT'. Must be an integer >= 1."
    exit 1
  fi
  if [[ ! "$CP_VCPU" =~ ^[0-9]+$ ]] || (( CP_VCPU < 2 )); then
    echo "Invalid --cp-cpus '$CP_VCPU'. kubeadm control-plane requires >= 2."
    exit 1
  fi
  if [[ ! "$WORKER_VCPU" =~ ^[0-9]+$ ]] || (( WORKER_VCPU < 1 )); then
    echo "Invalid --worker-cpus '$WORKER_VCPU'. Must be an integer >= 1."
    exit 1
  fi
  validate_size_arg "--cp-memory" "$CP_RAM"
  validate_size_arg "--worker-memory" "$WORKER_RAM"
  validate_size_arg "--cp-disk" "$CP_DISK"
  validate_size_arg "--worker-disk" "$WORKER_DISK"
  if (( $(size_to_mb "$CP_RAM") < 1700 )); then
    echo "Invalid --cp-memory '$CP_RAM'. kubeadm control-plane requires >= 1700M."
    exit 1
  fi
  if (( $(size_to_mb "$WORKER_RAM") < 1700 )); then
    echo "Invalid --worker-memory '$WORKER_RAM'. kubeadm node requires >= 1700M."
    exit 1
  fi
  init_nodes

  if ! command -v multipass &>/dev/null; then
    echo "Multipass is not installed. Run: sudo snap install multipass"
    exit 1
  fi

  # Check if VMs already exist
  if multipass list --format json 2>/dev/null | grep -q "\"$CP1\""; then
    read -p "Cluster '$CLUSTER_NAME' VMs already exist. Recreate? (y/N): " ans
    if [[ "$ans" =~ ^[yY]$ ]]; then
      multipass delete -p "${NODES[@]}" 2>/dev/null || true
    else
      echo "Aborted."
      exit 0
    fi
  fi

  confirm_resource_requirements
  create_vms
  log "Installing containerd + kubeadm on all nodes in parallel..."
  run_parallel_for_nodes "node install" install_k8s_node "${NODES[@]}"
  init_control_plane
  configure_kubeconfig
  install_cni
  join_nodes
  export_kubeconfig
  configure_host_kubeconfig

  log "Waiting for all nodes to be Ready..."
  sleep 30
  for node in "${NODES[@]}"; do
    multipass exec "$CP1" -- kubectl wait --for=condition=Ready "nodes/$node" --timeout=180s 2>/dev/null || true
  done
  multipass exec "$CP1" -- kubectl get nodes
  log "Done for cluster '$CLUSTER_NAME'! Kubeconfig: $HOST_KUBECONFIG"
}

main "$@"
