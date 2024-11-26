#!/bin/bash

set -e

command=/usr/share/openvswitch/scripts/ovs-ctl

function stop() {
    $command stop
    exit 0
}

function restart() {
    $command restart
}

trap "stop" SIGINT SIGTERM
trap "restart" SIGHUP

# Launch ovs daemons
$command start
sleep 2

ovs-vsctl add-br IXP
ovs-ofctl add-flow IXP action=NORMAL

chmod 0755 /home/.looking_glass.sh
/home/.looking_glass.sh &

# Loop while the daemons are alive.
# status returns exit code 0 only if all daemons are are running.
while $command status > /dev/null ; do
    sleep 0.5
done

$command status

exit 1 # exit unexpected
