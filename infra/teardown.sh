#!/bin/bash
# NSP midterm - remove everything provision.sh created.
# Only touches resources named nsp-* inside the personal project.
#   bash teardown.sh --yes
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
export OS_CLOUD="${OS_CLOUD:-hicat0x0}"

PROJECT=c606de79d0b84497a61df9c5db15e1a0   # hicat0x0 (personal project)

if [ "${1:-}" != "--yes" ]; then
  echo "This deletes the nsp-* servers (and their root volumes), ports,"
  echo "security group and network. Re-run with --yes to proceed."
  exit 1
fi

scoped=$(openstack token issue -f value -c project_id)
if [ "$scoped" != "$PROJECT" ]; then
  echo "token is scoped to $scoped, expected $PROJECT - aborting" >&2
  exit 1
fi

for id in $(openstack server list --project "$PROJECT" --name '^nsp-' -f value -c ID); do
  echo "== delete server $id"
  openstack server delete --wait "$id"
done

for id in $(openstack port list --project "$PROJECT" -f value -c ID -c Name |
            awk '$2 ~ /^nsp-.*-int$/ {print $1}'); do
  echo "== delete port $id"
  openstack port delete "$id"
done

sg_id=$(openstack security group list --project "$PROJECT" -f value -c ID -c Name |
  awk '$2=="nsp-internal"{print $1}')
if [ -n "$sg_id" ]; then
  echo "== delete security group nsp-internal"
  openstack security group delete "$sg_id"
fi

net_id=$(openstack network list --project "$PROJECT" --name nsp-net -f value -c ID)
if [ -n "$net_id" ]; then
  echo "== delete network nsp-net"
  openstack network delete "$net_id"
fi

echo "== leftovers (expect nothing below)"
openstack server list --project "$PROJECT" --name '^nsp-' -f value -c Name
openstack volume list --project "$PROJECT" -f value -c ID -c Name -c Status |
  awk '$2 ~ /^nsp-/' || true
