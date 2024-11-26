#!/bin/bash
#
# creates an initial configuration for every router
# load configuration into router

set -o errexit
set -o pipefail
set -o nounset

DIRECTORY="$1"
source "${DIRECTORY}/config/subnet_config.sh"
source "${DIRECTORY}/setup/_parallel_helper.sh"

# read configs
readarray groups < "${DIRECTORY}/config/AS_config.txt"
readarray extern_links < "${DIRECTORY}/config/aslevel_links.txt"
readarray l2_switches < "${DIRECTORY}/config/l2_switches.txt"
readarray l2_links < "${DIRECTORY}/config/l2_links.txt"
readarray l2_hosts < "${DIRECTORY}/config/l2_hosts.txt"

group_numbers="${#groups[@]}"
n_extern_links="${#extern_links[@]}"
n_l2_switches="${#l2_switches[@]}"
n_l2_links="${#l2_links[@]}"
n_l2_hosts="${#l2_hosts[@]}"

# create initial configuration for each router
for ((k = 0; k < group_numbers; k++)); do
    (
        group_k=(${groups[$k]})
        group_number="${group_k[0]}"
        group_as="${group_k[1]}"
        group_config="${group_k[2]}"
        group_router_config="${group_k[3]}"
        group_internal_links="${group_k[4]}"

        if [ "${group_as}" != "IXP" ]; then

            readarray routers < "${DIRECTORY}/config/${group_router_config}"
            readarray intern_links < "${DIRECTORY}/config/${group_internal_links}"
            n_routers="${#routers[@]}"
            n_intern_links="${#intern_links[@]}"

            # Initlization the associative array to configure the layer2 subnet advertisements
            declare -A l2_id
            idtmp=1
            for ((i = 0; i < n_routers; i++)); do
                router_i=(${routers[$i]})
                property2="${router_i[2]}"
                if [[ "${property2}" == *L2* ]]; then
                    l2_id[$property2]=0
                fi
            done
            for ((i = 0; i < n_routers; i++)); do
                router_i=(${routers[$i]})
                property2="${router_i[2]}"
                if [[ "${property2}" == *L2* ]]; then
                    if [[ "${l2_id[$property2]}" -eq "0" ]]; then
                        l2_id[$property2]=$idtmp
                        idtmp=$(($idtmp + 1))
                    fi
                fi
            done

            all_in_one="false"
            if [[ ${#router_i[@]} -gt 4 ]]; then
                if [[ "${router_i[4]}" == "ALL" ]]; then
                    all_in_one="true"
                fi
            fi

            # we only do it once if all-in-one setup
            for ((i = 0; i < n_routers; i++)); do
                if [[ "$all_in_one" == "true" && $i -gt 0 ]]; then
                    break
                fi
                router_i=(${routers[$i]})
                rname="${router_i[0]}"
                property1="${router_i[1]}"
                property2="${router_i[2]}"
                dname=$(echo $property2 | cut -s -d ':' -f 2)

                if [ ${#rname} -gt 10 ]; then
                    echo 'ERROR: Router names must have a length lower or equal than 10'
                    exit 1
                fi

                configdir="${DIRECTORY}/groups/g${group_number}/${rname}/config"
                # Create files and directoryu
                mkdir -p "${configdir}"
                echo "#!/usr/bin/vtysh -f" > "${configdir}/conf_init.sh"
                chmod +x "${configdir}/conf_init.sh"
                echo "#!/usr/bin/vtysh -f" > "${configdir}/conf_full.sh"
                chmod +x "${configdir}/conf_full.sh"
                location="${configdir}/conf_full.sh"

                {
                    echo "interface lo"
                    echo "ip address $(subnet_router ${group_number} ${i})"
                    echo "exit"
                    if [[ ! -z "${dname}" ]]; then
                        if [[ "$all_in_one" == "true" ]]; then
                            for ((j = 0; j < n_routers; j++)); do
                                router_j=(${routers[$j]})
                                if [ "${router_j[2]}" != "N/A" ]; then
                                    echo "interface host${j}"
                                    echo "ip address $(subnet_host_router ${group_number} ${j} router)"
                                    echo "exit"
                                    echo "router ospf"
                                    echo "network $(subnet_host_router ${group_number} ${j} router) area 0"
                                    echo "exit"
                                fi
                            done
                        else
                            echo "interface host"
                            echo "ip address $(subnet_host_router ${group_number} ${i} router)"
                            echo "exit"
                            echo "router ospf"
                            echo "network $(subnet_host_router ${group_number} ${i} router) area 0"
                            echo "exit"
                        fi
                    fi

                    if [[ "${property2}" == *L2* ]]; then
                        echo "router ospf"
                        echo "network $(subnet_l2_router ${group_number} $((${l2_id[$property2]} - 1))) area 0"
                        echo "exit"
                    fi

                    router_id="$(subnet_router ${group_number} ${i})"

                    echo "router ospf"
                    echo "ospf router-id ${router_id%/*}"
                    echo "network $(subnet_router ${group_number} ${i}) area 0"
                    echo "exit"
                    echo "ip route $(subnet_group ${group_number}) null0"
                    echo "ip prefix-list OWN_PREFIX seq 5 permit $(subnet_group ${group_number})"
                    echo "route-map OWN_PREFIX permit 10"
                    echo "match ip address prefix-list OWN_PREFIX"
                    echo "exit"

                    for ((j = 0; j < n_routers; j++)); do
                        if [[ "$all_in_one" == "true" && $i -gt 0 ]]; then
                            break
                        fi
                        router_j=(${routers[$j]})
                        rname2="${router_j[0]}"
                        if [ "${rname}" != "${rname2}" ]; then
                            subnet="$(subnet_router ${group_number} ${j})"
                            echo "router bgp ${group_number}"
                            echo "network $(subnet_group ${group_number})"
                            echo "neighbor ${subnet%???} remote-as ${group_number}"
                            echo "neighbor ${subnet%???} update-source lo"
                            echo "neighbor ${subnet%???} next-hop-self"
                            # echo "address-family ipv6 unicast"
                            # echo "neighbor ${subnet%???} activate"
                            # echo "exit"
                            echo "exit"
                        fi
                    done
                } >> "${location}"
            done

            for ((i = 0; i < n_intern_links; i++)); do
                row_i=(${intern_links[$i]})
                router1="${row_i[0]}"
                router2="${row_i[1]}"
                location1="${DIRECTORY}/groups/g${group_number}/${router1}/config/conf_full.sh"
                location2="${DIRECTORY}/groups/g${group_number}/${router2}/config/conf_full.sh"
                {
                    echo "interface port_${router2}"
                    echo "ip address $(subnet_router_router_intern ${group_number} ${i} 1)"
                    echo "ip ospf cost 1"
                    echo "exit"
                    echo "router ospf"
                    echo "network $(subnet_router_router_intern ${group_number} ${i} 1) area 0"
                    echo "exit"
                } >> "${location1}"
                {
                    echo "interface port_${router1}"
                    echo "ip address $(subnet_router_router_intern ${group_number} ${i} 2)"
                    echo "ip ospf cost 1"
                    echo "exit"
                    echo "router ospf"
                    echo "network $(subnet_router_router_intern ${group_number} ${i} 2) area 0"
                    echo "exit"
                } >> "${location2}"
            done

        else # If IXP
            configdir="${DIRECTORY}/groups/g${group_number}/config"
            mkdir -p "${configdir}"
            echo "#!/usr/bin/vtysh -f" > "${configdir}/conf_init.sh"
            chmod +x "${configdir}/conf_init.sh"
            echo "#!/usr/bin/vtysh -f" > "${configdir}/conf_full.sh"
            chmod +x "${configdir}/conf_full.sh"
            location="${configdir}/conf_full.sh"

            {

                for ((i = 0; i < n_extern_links; i++)); do
                    row_i=(${extern_links[$i]})
                    grp_1="${row_i[0]}"
                    router_grp_1="${row_i[1]}"
                    grp_2="${row_i[3]}"
                    router_grp_2="${row_i[4]}"

                    if [ "${group_number}" = "${grp_1}" ] || [ "${group_number}" = "${grp_2}" ]; then
                        if [ "${group_number}" = "${grp_1}" ]; then
                            grp_1="${row_i[2]}"
                            router_grp_1="${row_i[3]}"
                            grp_2="${row_i[0]}"
                            router_grp_2="${row_i[1]}"
                        fi

                        subnet1="$(subnet_router_IXP ${grp_1} ${grp_2} group)"
                        subnet2="$(subnet_router_IXP ${grp_1} ${grp_2} IXP)"

                        echo "bgp community-list ${grp_1} permit ${grp_2}:${grp_1}"
                        echo "route-map ${grp_1}_EXPORT permit 10"
                        echo "match community ${grp_1}"
                        echo "exit"
                        echo "route-map ${grp_1}_IMPORT permit 10"
                        echo "exit"
                        echo "router bgp ${grp_2}"
                        echo "bgp router-id 180.${grp_2}.0.${grp_2}"
                        echo "neighbor ${subnet1%/*} remote-as ${grp_1}"
                        echo "neighbor ${subnet1%/*} activate"
                        echo "neighbor ${subnet1%/*} route-server-client"
                        echo "neighbor ${subnet1%/*} route-map ${grp_1}_IMPORT in"
                        echo "neighbor ${subnet1%/*} route-map ${grp_1}_EXPORT out"
                        echo "exit"

                        docker exec -d "${group_number}_IXP" bash -c "ovs-vsctl add-port IXP grp_${grp_1}"
                    fi
                done
            } >> "${location}"
        fi
    ) &
    wait_if_n_tasks_are_running
done
wait

# for every connection in ./config/aslevel_links.txt
# configure the subnet as defined in ./config/subnet_config.sh
for ((i = 0; i < n_extern_links; i++)); do
    row_i=(${extern_links[$i]})
    grp_1="${row_i[0]}"
    router_grp_1="${row_i[1]}"
    relation_grp_1="${row_i[2]}"
    grp_2="${row_i[3]}"
    router_grp_2="${row_i[4]}"
    relation_grp_2="${row_i[5]}"
    throughput="${row_i[6]}"
    delay="${row_i[7]}"
    buffer="${row_i[8]}"

    for ((k = 0; k < group_numbers; k++)); do
        group_k=(${groups[$k]})
        group_number="${group_k[0]}"
        group_as="${group_k[1]}"

        if [ "${grp_1}" = "${group_number}" ]; then
            group_as_1="${group_as}"
        elif [ "${grp_2}" = "${group_number}" ]; then
            group_as_2="${group_as}"
        fi
    done

    if [ "${group_as_1}" = "IXP" ] || [ "${group_as_2}" = "IXP" ]; then
        if [ "${group_as_1}" = "IXP" ]; then
            grp_1="${row_i[3]}"
            router_grp_1="${row_i[4]}"
            grp_2="${row_i[0]}"
            router_grp_2="${row_i[1]}"
        fi

        ixp_peers="${row_i[9]}"

        subnet1="$(subnet_router_IXP ${grp_1} ${grp_2} group)"
        subnet2="$(subnet_router_IXP ${grp_1} ${grp_2} IXP)"
        location="${DIRECTORY}/groups/g${grp_1}/${router_grp_1}/config/conf_full.sh"

        {
            echo "interface ixp_${grp_2}"
            echo "ip address ${subnet1}"
            echo "exit"
            echo "router bgp ${grp_1}"
            echo "network $(subnet_group ${grp_1})"
            echo "neighbor ${subnet2%???} remote-as ${grp_2}"
            echo "neighbor ${subnet2%???} activate"
            echo "neighbor ${subnet2%???} route-map IXP_OUT_${grp_2} out"
            echo "neighbor ${subnet2%???} route-map IXP_IN_${grp_2} in"
            # The IXP does not add it's own AS to the AS_PATH which causes member rouers to drop routes from the IXP
            echo "no neighbor ${subnet2%???} enforce-first-as"
            echo "exit"

            str_tmp=''
            for peer in $(echo $ixp_peers | sed "s/,/ /g"); do
                str_tmp="${str_tmp}${grp_2}:${peer} "
            done

            echo "bgp community-list 1 permit ${grp_1}:10"
            echo "route-map IXP_OUT_${grp_2} permit 10"
            echo "set community $str_tmp"
            echo "match ip address prefix-list OWN_PREFIX"
            echo "exit"
            echo "route-map IXP_OUT_${grp_2} permit 20"
            echo "set community $str_tmp"
            echo "match community 1"
            echo "exit"
            echo "route-map IXP_IN_${grp_2} permit 10"
            echo "set community ${grp_1}:20"
            echo "set local-preference 50"

            echo "exit"
        } >> "${location}"
    else
        subnet="${row_i[9]}"

        if [ "$subnet" != "N/A" ]; then
            subnet1="${subnet%????}${grp_1}/24"
            subnet2="${subnet%????}${grp_2}/24"
        else
            subnet1="$(subnet_router_router_extern ${grp_1} ${grp_2})"
            subnet2="$(subnet_router_router_extern ${grp_2} ${grp_1})"
        fi

        location1="${DIRECTORY}/groups/g${grp_1}/${router_grp_1}/config/conf_full.sh"
        {
            echo "interface ext_${grp_2}_${router_grp_2}"
            echo "ip address ${subnet1}"
            echo "exit"
            echo "router bgp ${grp_1}"
            echo "neighbor ${subnet2%???} remote-as ${grp_2}"
            echo "neighbor ${subnet2%???} route-map LOCAL_PREF_IN_${grp_2} in"
            echo "neighbor ${subnet2%???} route-map LOCAL_PREF_OUT_${grp_2} out"
            echo "network $(subnet_group ${grp_1})"
            echo "exit"

            if [ $relation_grp_1 == 'Provider' ]; then
                echo "bgp community-list 2 permit ${grp_1}:10"
                echo "bgp community-list 2 permit ${grp_1}:20"
                echo "bgp community-list 2 permit ${grp_1}:30"
                echo "route-map LOCAL_PREF_IN_${grp_2} permit 10"
                echo "set community ${grp_1}:10"
                echo "set local-preference 100"
                echo "exit"
                echo "route-map LOCAL_PREF_OUT_${grp_2} permit 5"
                echo "match ip address prefix-list OWN_PREFIX"
                echo "exit"
                echo "route-map LOCAL_PREF_OUT_${grp_2} permit 10"
                echo "match community 2"
                echo "exit"
            elif [ $relation_grp_1 == 'Customer' ]; then
                echo "bgp community-list 1 permit ${grp_1}:10"
                echo "route-map LOCAL_PREF_IN_${grp_2} permit 10"
                echo "set community ${grp_1}:30"
                echo "set local-preference 20"
                echo "exit"
                echo "route-map LOCAL_PREF_OUT_${grp_2} permit 5"
                echo "match ip address prefix-list OWN_PREFIX"
                echo "exit"
                echo "route-map LOCAL_PREF_OUT_${grp_2} permit 10"
                echo "match community 1"
                echo "exit"
            elif [ $relation_grp_1 == 'Peer' ]; then
                echo "bgp community-list 1 permit ${grp_1}:10"
                echo "route-map LOCAL_PREF_IN_${grp_2} permit 10"
                echo "set community ${grp_1}:20"
                echo "set local-preference 50"
                echo "exit"
                echo "route-map LOCAL_PREF_OUT_${grp_2} permit 5"
                echo "match ip address prefix-list OWN_PREFIX"
                echo "exit"
                echo "route-map LOCAL_PREF_OUT_${grp_2} permit 10"
                echo "match community 1"
                echo "exit"
            fi
        } >> "${location1}"

        location2="${DIRECTORY}/groups/g${grp_2}/${router_grp_2}/config/conf_full.sh"
        {
            echo "interface ext_${grp_1}_${router_grp_1}"
            echo "ip address ${subnet2}"
            echo "exit"
            echo "router bgp ${grp_2}"
            echo "neighbor ${subnet1%???} remote-as ${grp_1}"
            echo "neighbor ${subnet1%???} route-map LOCAL_PREF_IN_${grp_1} in"
            echo "neighbor ${subnet1%???} route-map LOCAL_PREF_OUT_${grp_1} out"
            echo "network $(subnet_group ${grp_2})"
            echo "exit"

            if [ $relation_grp_2 == 'Provider' ]; then
                echo "bgp community-list 2 permit ${grp_2}:10"
                echo "bgp community-list 2 permit ${grp_2}:20"
                echo "bgp community-list 2 permit ${grp_2}:30"
                echo "route-map LOCAL_PREF_IN_${grp_1} permit 10"
                echo "set community ${grp_2}:10"
                echo "set local-preference 100"
                echo "exit"
                echo "route-map LOCAL_PREF_OUT_${grp_1} permit 5"
                echo "match ip address prefix-list OWN_PREFIX"
                echo "exit"
                echo "route-map LOCAL_PREF_OUT_${grp_1} permit 10"
                echo "match community 2"
                echo "exit"
            elif [ $relation_grp_2 == 'Customer' ]; then
                echo "bgp community-list 1 permit ${grp_2}:10"
                echo "route-map LOCAL_PREF_IN_${grp_1} permit 10"
                echo "set community ${grp_2}:30"
                echo "set local-preference 20"
                echo "exit"
                echo "route-map LOCAL_PREF_OUT_${grp_1} permit 5"
                echo "match ip address prefix-list OWN_PREFIX"
                echo "exit"
                echo "route-map LOCAL_PREF_OUT_${grp_1} permit 10"
                echo "match community 1"
                echo "exit"
            elif [ $relation_grp_2 == 'Peer' ]; then
                echo "bgp community-list 1 permit ${grp_2}:10"
                echo "route-map LOCAL_PREF_IN_${grp_1} permit 10"
                echo "set community ${grp_2}:20"
                echo "set local-preference 50"
                echo "exit"
                echo "route-map LOCAL_PREF_OUT_${grp_1} permit 5"
                echo "match ip address prefix-list OWN_PREFIX"
                echo "exit"
                echo "route-map LOCAL_PREF_OUT_${grp_1} permit 10"
                echo "match community 1"
                echo "exit"
            fi
        } >> "${location2}"
    fi

done

# measurement
for ((k = 0; k < group_numbers; k++)); do
    (
        group_k=(${groups[$k]})
        group_number="${group_k[0]}"
        group_as="${group_k[1]}"
        group_config="${group_k[2]}"
        group_router_config="${group_k[3]}"
        group_internal_links="${group_k[4]}"

        if [ "${group_as}" != "IXP" ]; then

            readarray routers < "${DIRECTORY}/config/${group_router_config}"
            n_routers=${#routers[@]}

            for ((i = 0; i < n_routers; i++)); do
                router_i=(${routers[$i]})
                rname="${router_i[0]}"
                property1="${router_i[1]}"

                if [ "${property1}" = "MEASUREMENT" ]; then
                    location="${DIRECTORY}/groups/g${group_number}/${rname}/config/conf_init.sh"
                    {
                        echo "interface measurement_${group_number}"
                        echo "ip address $(subnet_router_MEASUREMENT ${group_number} group)"
                        echo "exit"
                        echo "router ospf"
                        echo "network $(subnet_router_MEASUREMENT ${group_number} group) area 0"
                        echo "exit"
                    } >> "${location}"
                fi
            done
        fi
    ) &
    wait_if_n_tasks_are_running
done
wait

# matrix
for ((k = 0; k < group_numbers; k++)); do
    (
        group_k=(${groups[$k]})
        group_number="${group_k[0]}"
        group_as="${group_k[1]}"
        group_config="${group_k[2]}"
        group_router_config="${group_k[3]}"
        group_internal_links="${group_k[4]}"

        if [ "${group_as}" != "IXP" ]; then

            readarray routers < "${DIRECTORY}/config/$group_router_config"
            n_routers=${#routers[@]}

            for ((i = 0; i < n_routers; i++)); do
                router_i=(${routers[$i]})
                rname="${router_i[0]}"
                property1="${router_i[1]}"

                if [ "${property1}" = "MATRIX" ]; then
                    location="${DIRECTORY}/groups/g${group_number}/${rname}/config/conf_init.sh"
                    {
                        echo "interface matrix_${group_number}"
                        echo "ip address $(subnet_router_MATRIX ${group_number} group)"
                        echo "exit"
                        echo "router ospf"
                        echo "network $(subnet_router_MATRIX ${group_number} group) area 0"
                        echo "exit"
                    } >> "${location}"
                fi
            done
        fi
    ) &
    wait_if_n_tasks_are_running
done
wait

# dns
for ((k = 0; k < group_numbers; k++)); do
    (
        group_k=(${groups[$k]})
        group_number="${group_k[0]}"
        group_as="${group_k[1]}"
        group_config="${group_k[2]}"
        group_router_config="${group_k[3]}"
        group_internal_links="${group_k[4]}"

        if [ "${group_as}" != "IXP" ]; then

            readarray routers < "${DIRECTORY}/config/$group_router_config"
            n_routers=${#routers[@]}

            for ((i = 0; i < n_routers; i++)); do
                router_i=(${routers[$i]})
                rname="${router_i[0]}"
                property1="${router_i[1]}"

                if [ "${property1}" = "DNS" ]; then
                    location="${DIRECTORY}/groups/g${group_number}/${rname}/config/conf_init.sh"
                    {
                        echo "interface dns_${group_number}"
                        echo "ip address $(subnet_router_DNS ${group_number} group)"
                        echo "exit"
                        echo "router ospf"
                        echo "network $(subnet_router_DNS ${group_number} group) area 0"
                        echo "exit"
                    } >> "${location}"
                fi
            done
        fi
    ) &
    wait_if_n_tasks_are_running
done
wait

echo 'Sleeping 2 seconds...'
sleep 2

for ((k = 0; k < group_numbers; k++)); do
    (
        group_k=(${groups[$k]})
        group_number="${group_k[0]}"
        group_as="${group_k[1]}"
        group_config="${group_k[2]}"
        group_config="${group_k[2]}"
        group_router_config="${group_k[3]}"
        group_internal_links="${group_k[4]}"

        if [ "${group_as}" != "IXP" ]; then

            readarray routers < "${DIRECTORY}/config/${group_router_config}"
            n_routers=${#routers[@]}

            for ((i = 0; i < n_routers; i++)); do
                router_i=(${routers[$i]})
                rname="${router_i[0]}"
                property1="${router_i[1]}"

                config_dir="${DIRECTORY}/groups/g${group_number}/${rname}/config"

                docker cp "${config_dir}/conf_init.sh" "${group_number}_${rname}router":/home/conf_init.sh > /dev/null
                docker exec -d "${group_number}_${rname}router" ./home/conf_init.sh &

                if [ "$group_config" == "Config" ]; then
                    docker cp "${config_dir}/conf_full.sh" "${group_number}_${rname}router":/home/conf_full.sh > /dev/null
                    docker exec -d "${group_number}_${rname}router" ./home/conf_full.sh &
                fi

            done
        else # IXP
            config_dir="${DIRECTORY}/groups/g${group_number}/config"
            docker cp "${config_dir}/conf_full.sh" "${group_number}_IXP":/conf_full.sh > /dev/null
            # The IXP is running an older Quagga version that does not support the
            # -f command, so we need to feed the file in manually as a workaround.
            # docker exec -d "${group_number}_IXP" ./conf_full.sh &
            # tail -n +2 removes the first shebang line of the file.
            docker exec -d "${group_number}_IXP" bash -c 'vtysh -c "conf t" -c "$(tail -n +2 conf_full.sh)" -c "exit"' &

            docker exec -d "${group_number}_IXP" bash -c "ifconfig IXP 180.${group_number}.0.${group_number}/24" &
        fi
    ) &
    wait_if_n_tasks_are_running # no ip command
done
wait
