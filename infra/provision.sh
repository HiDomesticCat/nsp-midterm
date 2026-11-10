#!/bin/bash
# NSP midterm - homework VMs on OpenStack (idempotent, safe to re-run).
#
# Isolation from the lab platform:
#   - everything is created in the personal project and is named nsp-*
#   - test traffic uses a dedicated network (nsp-net) with no router attached
#   - the existing personal network is used only for SSH and apt
#   - nothing is added to lab-infra / lab-iac or to any platform project
#
# Run on a host that has the openstack CLI and the `hicat0x0` cloud entry:
#   bash provision.sh [file-with-extra-ssh-public-key]
# Remove everything with teardown.sh.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
export OS_CLOUD="${OS_CLOUD:-hicat0x0}"

PROJECT=c606de79d0b84497a61df9c5db15e1a0        # hicat0x0 (personal project)
MGMT_NET=2fa2e6b0-40b8-44e5-ad58-de9769b0a437   # hicat0x0-professor (existing)
SG_SSH=0b309b56-b06b-4f3b-8809-a0b62501a25d     # existing project SG "ssh"
SG_PING=7f848db4-f761-4290-a78a-4c54122be956    # existing project SG "ping"
IMAGE=dc24457b-4554-4d37-a8ad-0d6e376ab27e      # Ubuntu-24.04-Noble
KEYPAIR=lab-key

NET=nsp-net
SUBNET=nsp-subnet
CIDR=10.77.0.0/24
SG=nsp-internal

# name:flavor:root-disk-GB:address-on-nsp-net:role
VMS="nsp-server:2c4g:20:10.77.0.10:dev
nsp-client-1:1c2g:10:10.77.0.21:client
nsp-client-2:1c2g:10:10.77.0.22:client"

EXTRA_KEY=""
if [ "${1:-}" != "" ]; then
  EXTRA_KEY=$(tr -d '\r' < "$1" | head -1)
fi

say() { printf '== %s\n' "$*"; }

# The cloud user is an admin, so names can collide across projects.
# Refuse to run unless the token is scoped to the personal project.
scoped=$(openstack token issue -f value -c project_id)
if [ "$scoped" != "$PROJECT" ]; then
  echo "token is scoped to $scoped, expected $PROJECT - aborting" >&2
  exit 1
fi

# ---- network -------------------------------------------------------------
net_id=$(openstack network list --project "$PROJECT" --name "$NET" -f value -c ID)
if [ -z "$net_id" ]; then
  if openstack subnet list -f value -c Subnet | grep -qxF "$CIDR"; then
    echo "$CIDR is already used by another subnet - aborting" >&2
    exit 1
  fi
  say "create network $NET"
  net_id=$(openstack network create "$NET" \
    --description "NSP midterm homework: isolated test network, no router" \
    -f value -c id)
fi

subnet_id=$(openstack subnet list --project "$PROJECT" --name "$SUBNET" -f value -c ID)
if [ -z "$subnet_id" ]; then
  say "create subnet $SUBNET $CIDR"
  subnet_id=$(openstack subnet create "$SUBNET" --network "$net_id" \
    --subnet-range "$CIDR" --gateway none --dhcp \
    --allocation-pool start=10.77.0.100,end=10.77.0.200 \
    -f value -c id)
fi

# ---- security group for the isolated network -------------------------------
sg_id=$(openstack security group list --project "$PROJECT" -f value -c ID -c Name |
  awk -v n="$SG" '$2==n{print $1}')
if [ -z "$sg_id" ]; then
  say "create security group $SG"
  sg_id=$(openstack security group create "$SG" \
    --description "NSP midterm homework: members may talk to each other on nsp-net" \
    -f value -c id)
  openstack security group rule create --ingress --ethertype IPv4 \
    --protocol any --remote-group "$sg_id" "$sg_id" >/dev/null
fi

# ---- cloud-init ------------------------------------------------------------
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

user_data() {  # $1 = role
  local f="$workdir/user-data-$1"
  {
    echo "#cloud-config"
    echo "timezone: Asia/Taipei"
    echo "manage_etc_hosts: false"
    if [ -n "$EXTRA_KEY" ]; then
      echo "ssh_authorized_keys:"
      echo "  - $EXTRA_KEY"
    fi
    echo "package_update: true"
    echo "packages:"
    if [ "$1" = dev ]; then
      for p in build-essential gdb valgrind make cmake pkg-config git \
               tcpdump tshark strace ltrace cppcheck netcat-openbsd \
               manpages-dev manpages-posix-dev tmux htop jq; do
        echo "  - $p"
      done
    else
      for p in tcpdump strace gdb netcat-openbsd tmux libasan8 libubsan1; do
        echo "  - $p"
      done
    fi
    echo "runcmd:"
    echo "  - |"
    echo "    grep -q nsp-server /etc/hosts || printf '%s\n' '10.77.0.10 nsp-server' '10.77.0.21 nsp-client-1' '10.77.0.22 nsp-client-2' >> /etc/hosts"
    echo "  - touch /var/lib/nsp-ready"
  } > "$f"
  echo "$f"
}

# ---- servers ---------------------------------------------------------------
echo "$VMS" | while IFS=: read -r name flavor disk ip role; do
  port_id=$(openstack port list --project "$PROJECT" --name "$name-int" -f value -c ID)
  if [ -z "$port_id" ]; then
    say "create port $name-int $ip"
    port_id=$(openstack port create "$name-int" --network "$net_id" \
      --fixed-ip "subnet=$subnet_id,ip-address=$ip" \
      --security-group "$sg_id" \
      --description "NSP midterm homework" -f value -c id </dev/null)
  fi

  srv_id=$(openstack server list --project "$PROJECT" --name "^$name\$" -f value -c ID </dev/null)
  if [ -n "$srv_id" ]; then
    say "$name already exists ($srv_id)"
    continue
  fi

  say "create server $name ($flavor, ${disk}G)"
  ud=$(user_data "$role")
  openstack server create "$name" --flavor "$flavor" \
    --block-device "uuid=$IMAGE,source_type=image,destination_type=volume,volume_size=$disk,boot_index=0,delete_on_termination=true" \
    --key-name "$KEYPAIR" \
    --nic "net-id=$MGMT_NET" --nic "port-id=$port_id" \
    --security-group "$SG_SSH" --security-group "$SG_PING" \
    --user-data "$ud" \
    --property purpose=nsp-midterm \
    --wait -f value -c status </dev/null
done

say "result"
openstack server list --project "$PROJECT" --name '^nsp-' \
  -f value -c Name -c Status -c Networks -c Flavor
