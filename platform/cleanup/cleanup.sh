#!/bin/bash
#
# remove all container, bridges and temporary files
# will only remove the containers, bridges defined in ../config/

# set -x
set -o errexit
set -o pipefail
set -o nounset

if [ "$#" != 1 ]; then
  echo "usage: ${0##*/} directory" 2>&1
  exit 1
fi

# root privilege check in case this script is directly executed
if (($UID != 0)); then
    echo "$0 needs to be run as root"
    exit 1
fi

DIRECTORY="$1"

# kill all container
./cleanup/container_cleanup.sh "${DIRECTORY}"

# remove all container & restart docker
# remove all stopped containers, unused networks, dangling images and unused caches
# -f: no confirmation
docker system prune -f

# find all namespaces with dangling symbolic links and remove them
find /var/run/netns -xtype l -delete

# # clear stale ovs interfaces on the server
interface_list=$(ip link | grep -E '(_c@|vpn|_l|_a|_b|veth)' | awk -F': ' '{print $2}' | cut -d'@' -f1 || true) # ignore errors

# Check if interface_list is not empty
if [ -n "$interface_list" ]; then
    echo "$interface_list" | while read -r interface; do
        # Delete the interface, ignoring any errors
        ip link delete "$interface" || true
    done
fi


echo -n "ovs-vsctl " > "${DIRECTORY}"/ovs_command.txt

./cleanup/host_links_cleanup.sh "${DIRECTORY}"
./cleanup/layer2_cleanup.sh "${DIRECTORY}"
./cleanup/internal_links_cleanup.sh "${DIRECTORY}"
./cleanup/external_links_cleanup.sh "${DIRECTORY}"
./cleanup/measurement_cleanup.sh "${DIRECTORY}"
./cleanup/matrix_cleanup.sh "${DIRECTORY}"
./cleanup/dns_cleanup.sh "${DIRECTORY}"
./cleanup/ssh_cleanup.sh "${DIRECTORY}"
./cleanup/vpn_cleanup.sh "${DIRECTORY}"


# ensure any failure in the executed commands does not stop the script due to errexit
bash  < "${DIRECTORY}"/ovs_command.txt || true
rm -f "${DIRECTORY}"/ovs_command.txt

# delete old running config files
if [ -e "${DIRECTORY}"/groups ]; then
  rm -rf "${DIRECTORY}"/groups
fi
