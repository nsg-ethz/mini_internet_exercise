#!/bin/bash
#
# create all group containers(ssh, routers, hosts, switches)
set -o errexit
set -o pipefail
set -o nounset

DIRECTORY=$(readlink -f $1)
source "${DIRECTORY}"/config/variables.sh
source "${DIRECTORY}"/config/subnet_config.sh
source "${DIRECTORY}"/setup/_parallel_helper.sh

touch "${DIRECTORY}/groups/rpki/krill_containers.txt"

# read configs
readarray groups < "${DIRECTORY}"/config/AS_config.txt
group_numbers=${#groups[@]}

rpki_location="${DIRECTORY}/groups/rpki"

krill_container_list_file="${rpki_location}/krill_containers.txt"
routinator_container_list_file="${rpki_location}/routinator_containers.txt"
container_list_file="${DIRECTORY}/groups/docker_containers.txt"

# Create empty file or clear its content if the file already exists.
>$krill_container_list_file
>$routinator_container_list_file
>$container_list_file

# create a docker network to connect all ssh proxy containers
ssh_to_grp_bname="ssh_bridge"
subnet_ssh_to_grp="$(subnet_ext_sshContainer -1 "docker")"
docker network create --driver bridge --internal --subnet="${subnet_ssh_to_grp}" "${ssh_to_grp_bname}" > /dev/null

#create all container
for ((k = 0; k < group_numbers; k++)); do
    (
        group_k=(${groups[$k]})
        group_number="${group_k[0]}"
        group_as="${group_k[1]}"
        group_router_config="${group_k[3]}"
        group_layer2_switches="${group_k[5]}"
        group_layer2_hosts="${group_k[6]}"

        declare -a CONTAINERS
        declare -a KRILL_CONTAINERS
        declare -a ROUTINATOR_CONTAINERS

        # create a docker network to connect all ssh containers in one group
        # which later connects them to the measurement container.
        ssh_to_ctn_bname="${group_number}_ssh"
        subnet_ssh_to_ctn="$(subnet_sshContainer_groupContainer "${group_number}" -1 -1 "docker")"
        docker network create --driver bridge --internal --subnet="${subnet_ssh_to_ctn}" "${ssh_to_ctn_bname}" > /dev/null

        # echo "Group ${group_number}: creating containers..."

        if [ "${group_as}" != "IXP" ]; then

            readarray routers < "${DIRECTORY}"/config/$group_router_config
            readarray l2_switches < "${DIRECTORY}"/config/$group_layer2_switches
            readarray l2_hosts < "${DIRECTORY}"/config/$group_layer2_hosts
            n_routers=${#routers[@]}
            n_l2_switches=${#l2_switches[@]}
            n_l2_hosts=${#l2_hosts[@]}

            location="${DIRECTORY}"/groups/g"${group_number}"
            subnet_dns="$(subnet_router_DNS "${group_number}" "dns-group")"

            # start ssh container
            # the interface connecting to the bridge ssh_to_group
            subnet_ssh_to_grp="$(subnet_ext_sshContainer "${group_number}" sshContainer)"
            # the interface connecting to the bridge ssh_to_ctn
            subnet_ssh_to_ctn="$(subnet_sshContainer_groupContainer "${group_number}" -1 -1 "sshContainer")"
            docker run -itd --name="${group_number}_ssh" \
                --cpus=2 --pids-limit 100 --hostname="g${group_number}-proxy" --cap-add=NET_ADMIN \
                -v "${location}"/goto.sh:/root/goto.sh \
                -v "${location}"/save_configs.sh:/root/save_configs.sh \
                -v "${location}"/restore_configs.sh:/root/restore_configs.sh \
                -v "${location}"/restart_ospfd.sh:/root/restart_ospfd.sh \
                -v /etc/timezone:/etc/timezone:ro \
                -v /etc/localtime:/etc/localtime:ro \
                -v "${DIRECTORY}"/config/ssh_welcome_message.txt:/etc/motd:ro \
                --log-opt max-size=1m --log-opt max-file=3 \
                --network="bridge" -p "$((group_number + 2000)):22" \
                "${DOCKERHUB_PREFIX}d_ssh" > /dev/null # suppress container id output

            # connect to the ssh container network and rename interface
            docker network connect --ip="${subnet_ssh_to_grp%/*}" "$ssh_to_grp_bname" "${group_number}_ssh"
            docker exec "${group_number}"_ssh ip link set dev eth1 down
            docker exec "${group_number}"_ssh ip link set dev eth1 name ssh
            docker exec "${group_number}"_ssh ip link set dev ssh up

            # connect to the group container network and rename interface
            docker network connect --ip="${subnet_ssh_to_ctn%/*}" "$ssh_to_ctn_bname" "${group_number}_ssh"
            docker exec "${group_number}"_ssh ip link set dev eth2 down
            docker exec "${group_number}"_ssh ip link set dev eth2 name ssh_to_as
            docker exec "${group_number}"_ssh ip link set dev ssh_to_as up

            CONTAINERS+=("${group_number}_ssh")

            # start switches
            for ((l = 0; l < n_l2_switches; l++)); do

                switch_l=(${l2_switches[$l]})
                l2name="${switch_l[0]}"
                sname="${switch_l[1]}"

                subnet_ssh_switch="$(subnet_sshContainer_groupContainer "${group_number}" -1 "${l}" "switch")"

                docker run -itd --dns="${subnet_dns%/*}" --cap-add=NET_ADMIN \
                    --cpus=2 --pids-limit 1024 --hostname "${sname}" \
                    --name=${group_number}_L2_${l2name}_${sname} \
                    --cap-add=ALL \
                    --cap-drop=SYS_RESOURCE \
                    --sysctl net.ipv4.ip_forward=1 \
                    --sysctl net.ipv4.icmp_ratelimit=0 \
                    --sysctl net.ipv4.fib_multipath_hash_policy=1 \
                    --sysctl net.ipv4.conf.all.rp_filter=0 \
                    --sysctl net.ipv4.conf.default.rp_filter=0 \
                    --sysctl net.ipv4.conf.lo.rp_filter=0 \
                    --sysctl net.ipv4.icmp_echo_ignore_broadcasts=0 \
                    --sysctl net.ipv6.conf.all.disable_ipv6=0 \
                    --sysctl net.ipv6.conf.all.forwarding=1 \
                    --sysctl net.ipv6.icmp.ratelimit=0 \
                    -v /etc/timezone:/etc/timezone:ro \
                    -v /etc/localtime:/etc/localtime:ro \
                    --log-opt max-size=1m --log-opt max-file=3 \
                    --network="${ssh_to_ctn_bname}" --ip="${subnet_ssh_switch%/*}" \
                    "${DOCKERHUB_PREFIX}d_switch" > /dev/null
                # echo ${group_number}_L2_${l2name}_${sname}

                # rename eth0 interface to ssh in the switch container
                docker exec ${group_number}_L2_${l2name}_${sname} ip link set dev eth0 down
                docker exec ${group_number}_L2_${l2name}_${sname} ip link set dev eth0 name ssh
                docker exec ${group_number}_L2_${l2name}_${sname} ip link set dev ssh up

                CONTAINERS+=(${group_number}_L2_${l2name}_${sname})

            done

            # start hosts in l2 network
            for ((l = 0; l < n_l2_hosts; l++)); do
                host_l=(${l2_hosts[$l]})
                hname="${host_l[0]}"
                dname="${host_l[1]}"
                l2name="${host_l[2]}"
                sname="${host_l[3]}"

                subnet_ssh_host="$(subnet_sshContainer_groupContainer "${group_number}" -1 "${l}" "L2-host")"

                if [[ $hname != vpn* ]]; then
                    docker run -itd --dns="${subnet_dns%/*}" --cap-add=NET_ADMIN \
                        --cpus=2 --pids-limit 100 --hostname "${hname}" \
                        --name="${group_number}""_L2_""${l2name}""_""${hname}" \
                        --sysctl net.ipv4.icmp_ratelimit=0 \
                        --sysctl net.ipv4.icmp_echo_ignore_broadcasts=0 \
                        --sysctl net.ipv6.conf.all.disable_ipv6=0 \
                        --sysctl net.ipv6.icmp.ratelimit=0 \
                        -v /etc/timezone:/etc/timezone:ro \
                        -v /etc/localtime:/etc/localtime:ro \
                        --log-opt max-size=1m --log-opt max-file=3 \
                        --network="${ssh_to_ctn_bname}" --ip="${subnet_ssh_host%/*}" \
                        $dname > /dev/null

                    # rename eth0 interface to ssh in the host container
                    docker exec ${group_number}_L2_${l2name}_${hname} ip link set dev eth0 down
                    docker exec ${group_number}_L2_${l2name}_${hname} ip link set dev eth0 name ssh
                    docker exec ${group_number}_L2_${l2name}_${hname} ip link set dev ssh up

                    CONTAINERS+=("${group_number}""_L2_""${l2name}""_""${hname}")
                fi
            done

            # start routers and hosts
            for ((i = 0; i < n_routers; i++)); do
                router_i=(${routers[$i]})
                rname="${router_i[0]}"
                property1="${router_i[1]}"
                property2="${router_i[2]}"
                htype=$(echo $property2 | cut -d ':' -f 1)
                dname=$(echo $property2 | cut -d ':' -f 2)

                # location="${DIRECTORY}"/groups/g"${group_number}"/"${rname}"
                # for tier-1 and stub ASes, connect all services to the same router
                all_in_one="false"
                if [[ ${#router_i[@]} -gt 4 ]]; then
                    if [[ "${router_i[4]}" == "ALL" ]]; then
                        all_in_one="true"
                    fi
                fi

                # we only do it the first time if everything runs on the same router
                if [[ "$all_in_one" == "false" || $i -eq 0 ]]; then

                    location="${DIRECTORY}"/groups/g"${group_number}"/"${rname}"

                    subnet_ssh_router="$(subnet_sshContainer_groupContainer "${group_number}" "${i}" -1 "router")"

                    # start router
                    docker run -itd --dns="${subnet_dns%/*}" \
                        --name="${group_number}""_""${rname}""router" \
                        --sysctl net.ipv4.ip_forward=1 \
                        --sysctl net.ipv4.icmp_ratelimit=0 \
                        --sysctl net.ipv4.fib_multipath_hash_policy=1 \
                        --sysctl net.ipv4.conf.all.rp_filter=0 \
                        --sysctl net.ipv4.conf.default.rp_filter=0 \
                        --sysctl net.ipv4.conf.lo.rp_filter=0 \
                        --sysctl net.ipv4.icmp_echo_ignore_broadcasts=0 \
                        --sysctl net.ipv4.tcp_l3mdev_accept=1 \
                        --sysctl net.ipv6.conf.all.disable_ipv6=0 \
                        --sysctl net.ipv6.conf.all.forwarding=1 \
                        --sysctl net.ipv6.icmp.ratelimit=0 \
                        --sysctl net.mpls.conf.lo.input=1 \
                        --sysctl net.mpls.platform_labels=1048575 \
                        --cap-add=ALL \
                        --cap-drop=SYS_RESOURCE \
                        --cpus=2 --pids-limit 100 --hostname "${rname}""_router" \
                        -v "${location}"/looking_glass.txt:/home/looking_glass.txt \
                        -v "${location}"/looking_glass_json.txt:/home/looking_glass_json.txt \
                        -v "${location}"/daemons:/etc/frr/daemons \
                        -v "${location}"/frr.conf:/etc/frr/frr.conf \
                        -v /etc/timezone:/etc/timezone:ro \
                        --log-opt max-size=1m --log-opt max-file=3 \
                        --network="${ssh_to_ctn_bname}" --ip="${subnet_ssh_router%/*}" \
                        "${DOCKERHUB_PREFIX}d_router" > /dev/null

                    # rename eth0 interface to ssh in the router container
                    docker exec "${group_number}""_""${rname}""router" ip link set dev eth0 down
                    docker exec "${group_number}""_""${rname}""router" ip link set dev eth0 name ssh
                    docker exec "${group_number}""_""${rname}""router" ip link set dev ssh up

                    CONTAINERS+=("${group_number}""_""${rname}""router")
                fi

                # start host
                if [[ "${property2}" != "N/A" ]]; then
                    # container_name="${group_number}_${rname}host"
                    extra=""
                    if [[ "$all_in_one" == "true" ]]; then
                        extra="${i}"
                    fi

                    subnet_ssh_host="$(subnet_sshContainer_groupContainer "${group_number}" "${i}" -1 "L3-host")"

                    container_name="${group_number}_${rname}host${extra}"
                    additional_args=()
                    net="none"

                    if [[ "${htype}" == *"krill"* ]]; then
                        KRILL_CONTAINERS+=("${group_number} ${container_name}")
                        krill_auth_token=$(<"${DIRECTORY}/groups/g${group_number}/krill/krill_token.txt")
                        additional_args+=("--add-host" "rpki-server.group${group_number}:127.0.0.1")
                        additional_args+=("-e" "KRILL_CLI_TOKEN=${krill_auth_token}")
                        additional_args+=("-v" "${rpki_location}/tals:/var/krill/tals")
                        additional_args+=("-v" "${rpki_location}/root.crt:/usr/local/share/ca-certificates/root.crt:ro")
                        additional_args+=("-v" "${DIRECTORY}/groups/g${group_number}/krill/data:/var/krill/data")
                        additional_args+=("-v" "${DIRECTORY}/groups/g${group_number}/krill/krill.includesprivatekey.pem:/etc/ssl/certs/cert.includesprivatekey.pem:ro")
                        additional_args+=("-v" "${DIRECTORY}/groups/g${group_number}/krill/krill.crt:/var/krill/data/ssl/cert.pem:ro")
                        additional_args+=("-v" "${DIRECTORY}/groups/g${group_number}/krill/krill.key:/var/krill/data/ssl/key.pem:ro")
                        additional_args+=("-v" "${DIRECTORY}/groups/g${group_number}/krill/krill.conf:/var/krill/krill.conf:ro")
                        additional_args+=("-v" "${DIRECTORY}/groups/g${group_number}/krill/setup.sh:/home/setup.sh:ro")
                        additional_args+=("-v" "${DIRECTORY}/config/roas:/var/krill/roas:ro")
                        # Use bridge network for krill in order to connect to the web proxy container
                        # and use an https connection from the ouside world to reach the krill website
                        additional_args+=("-p" "3080:3080")

                        # Enable traefik
                        additional_args+=("-l" "traefik.enable=true")
                        additional_args+=("-l" "traefik.http.routers.krill.entrypoints=krill")

                    elif [[ "${htype}" == *"routinator"* ]]; then
                        ROUTINATOR_CONTAINERS+=("${group_number} ${container_name}")
                        additional_args+=("-v" "${rpki_location}/root.crt:/usr/local/share/ca-certificates/root.crt:ro")
                        additional_args+=("-v" "${rpki_location}/tals:/root/.rpki-cache/tals:ro")
                        additional_args+=("-v" "${DIRECTORY}/groups/g${group_number}/rpki_exceptions.json:/root/rpki_exceptions.json")
                        additional_args+=("-v" "${DIRECTORY}/groups/g${group_number}/rpki_exceptions_autograder.json:/root/rpki_exceptions_autograder.json")
                    fi

                    docker run -itd --dns="${subnet_dns%/*}" \
                        --name="${container_name}" --cap-add=NET_ADMIN \
                        --cpus=2 --pids-limit 100 --hostname "${rname}""_host${extra}" \
                        --sysctl net.ipv4.icmp_ratelimit=0 \
                        --sysctl net.ipv4.icmp_echo_ignore_broadcasts=0 \
                        --sysctl net.ipv6.conf.all.disable_ipv6=0 \
                        --sysctl net.ipv6.icmp.ratelimit=0 \
                        -v /etc/timezone:/etc/timezone:ro \
                        -v /etc/localtime:/etc/localtime:ro \
                        --log-opt max-size=1m --log-opt max-file=3 \
                        "${additional_args[@]}" \
                        --network="${ssh_to_ctn_bname}" --ip="${subnet_ssh_host%/*}" \
                        $dname > /dev/null
                    # add this for bgpsimple -v ${DIRECTORY}/docker_images/host/bgpsimple.pl:/home/bgpsimple.pl \

                    # rename eth0 interface to ssh in the host container
                    docker exec "${container_name}" ip link set dev eth0 down
                    docker exec "${container_name}" ip link set dev eth0 name ssh
                    docker exec "${container_name}" ip link set dev ssh up

                    if [[ "${htype}" == *"krill"* ]]; then
                        # Connect to the bridge for access via the web proxy.
                        docker network connect "bridge" "${container_name}"
                    fi
                    CONTAINERS+=("${container_name}")
                fi
            done

        elif [ "${group_as}" = "IXP" ]; then

            location="${DIRECTORY}"/groups/g"${group_number}"
            docker run -itd --net='none' --name="${group_number}""_IXP" \
                --pids-limit 200 --hostname "${group_number}""_IXP" \
                -v "${location}"/daemons:/etc/frr/daemons \
                --privileged \
                --sysctl net.ipv4.ip_forward=1 \
                --sysctl net.ipv4.icmp_ratelimit=0 \
                --sysctl net.ipv4.fib_multipath_hash_policy=1 \
                --sysctl net.ipv4.conf.all.rp_filter=0 \
                --sysctl net.ipv4.conf.default.rp_filter=0 \
                --sysctl net.ipv4.conf.lo.rp_filter=0 \
                --sysctl net.ipv4.icmp_echo_ignore_broadcasts=0 \
                --sysctl net.ipv6.conf.all.disable_ipv6=0 \
                --sysctl net.ipv6.conf.all.forwarding=1 \
                --sysctl net.ipv6.icmp.ratelimit=0 \
                -v /etc/timezone:/etc/timezone:ro \
                -v /etc/localtime:/etc/localtime:ro \
                -v "${location}"/looking_glass.txt:/home/looking_glass.txt \
                --log-opt max-size=1m --log-opt max-file=3 \
                "${DOCKERHUB_PREFIX}d_ixp" > /dev/null

            CONTAINERS+=("${group_number}""_IXP")
        fi

        printf '%b\n' "${ROUTINATOR_CONTAINERS[@]}" >> $routinator_container_list_file
        printf '%b\n' "${KRILL_CONTAINERS[@]}" >> $krill_container_list_file
        printf '%b\n' "${CONTAINERS[@]}" >> $container_list_file

        echo "Group ${group_number}: ${#CONTAINERS[@]} containers created!"
    ) &

    wait_if_n_tasks_are_running
done

wait

# Read container list from file
readarray -t CONTAINERS <$container_list_file

# Cache the docker pid to avoid calling docker inspect multiple times
# Access via setup/ovs-docker.sh get_docker_pid
readarray -t PIDS <<<$(docker inspect -f '{{.State.Pid}}' "${CONTAINERS[@]}")
declare -A DOCKER_TO_PID
for ((i = 0; i < ${#CONTAINERS[@]}; ++i)); do
    if [[ $(lsb_release -rs) == 16* ]]; then
        DOCKER_TO_PID["${CONTAINERS[$i]}"]=$(echo $PIDS | cut -f $(($i + 1)) -d ' ')
    else
        DOCKER_TO_PID["${CONTAINERS[$i]}"]=${PIDS[$i]}
    fi
done

declare -p DOCKER_TO_PID > ${DIRECTORY}/groups/docker_pid.map
