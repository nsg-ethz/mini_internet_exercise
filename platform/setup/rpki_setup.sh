#!/bin/bash
#
# Applies configurations which require a running container.
# This is the second part of the RPKI related startup script.

set -o errexit
set -o pipefail
set -o nounset

DIRECTORY="$1"

source "${DIRECTORY}"/config/subnet_config.sh
source "${DIRECTORY}"/setup/_parallel_helper.sh

# read configs
readarray groups < "${DIRECTORY}"/config/AS_config.txt
readarray extern_links < "${DIRECTORY}"/config/aslevel_links.txt
readarray krill_containers < "${DIRECTORY}"/groups/rpki/krill_containers.txt
readarray routinator_containers < "${DIRECTORY}"/groups/rpki/routinator_containers.txt

group_numbers=${#groups[@]}
n_extern_links=${#extern_links[@]}
n_krill_containers=${#krill_containers[@]}
n_routinator_containers=${#routinator_containers[@]}

for ((j = 0; j < n_krill_containers; j++)); do

    container_data=(${krill_containers[$j]})
    n_container_data=${#container_data[@]}

    # Filter out empty lines
    if [ $n_container_data -ge 2 ]; then
        group_number="${container_data[0]}"
        container_name="${container_data[1]}"

        # # Remove the default route on the krill container.
        # # The default route exists because of the docker bridge used to connect krill to the http proxy
        # docker exec $container_name ip route del 0/0

        # Enable ssh port forwarding to krill webserver via ssh proxy container (and only port forwarding)
        docker exec ${group_number}_ssh bash -c "echo 'restrict,port-forwarding,command=\"/bin/false\" $(cat groups/rpki/id_rsa_krill_webserver.pub)' >> ~/.ssh/authorized_keys"

        # Setup Certificate Authority and predefined ROAs
        docker exec $container_name /bin/bash /home/setup.sh
        sleep 5

        # Extract TAL file
        docker exec $container_name wget -q -O /var/krill/tals/group${group_number}.tal https://127.0.0.1:3000/ta/ta.tal

    fi

done

wait

for ((j = 0; j < n_routinator_containers; j++)); do
    container_data=(${routinator_containers[$j]})
    n_container_data=${#container_data[@]}

    # Filter out empty lines
    if [ $n_container_data -ge 2 ]; then
        group_number="${container_data[0]}"
        container_name="${container_data[1]}"

        # Reload routinator as the TAL files have been updated and force a cache update.
        docker exec $container_name bash -c "kill -1 \$(cat /var/run/routinator.pid)"
    fi
done

wait

for ((j = 0; j < n_krill_containers; j++)); do
    krill_container_data=(${krill_containers[$j]})
    n_container_data=${#krill_container_data[@]}

    # Filter out empty lines
    if [ $n_container_data -ge 2 ]; then
        krill_group_number="${krill_container_data[0]}"
        krill_container_name="${krill_container_data[1]}"
        krill_group_location="${DIRECTORY}/groups/g${krill_group_number}/krill"
        krill_config_location="${krill_group_location}/krill.conf"

        # Add one admin account and one readonly account which can see all certificate authorities
        admin_passwd=$(awk '$1 == "admin" { print $2 }' "${DIRECTORY}/groups/krill_passwords.txt")
        readonly_passwd=$(awk '$1 == "readonly" { print $2 }' "${DIRECTORY}/groups/krill_passwords.txt")
        {
            # Add admin user
            docker exec -i "$krill_container_name" bash -c "script -q -c 'krillc config user --id \"admin@ethz.ch\" -a \"role=admin\"' /dev/null" <<< "${admin_passwd}" | grep "admin" | tr -d '\r'

            # Add readonly user
            docker exec -i "$krill_container_name" bash -c "script -q -c 'krillc config user --id \"readonly@ethz.ch\" -a \"role=readonly\"' /dev/null" <<< "${readonly_passwd}" | grep "readonly" | tr -d '\r'
        } >> "$krill_config_location"
    fi
done

wait

for ((k = 0; k < group_numbers; k++)); do
    group_k=(${groups[$k]})
    group_number="${group_k[0]}"
    group_as="${group_k[1]}"
    group_config="${group_k[2]}"
    group_router_config="${group_k[3]}"
    group_internal_links="${group_k[4]}"

    if [ "${group_as}" != "IXP" ]; then
        readarray routers < "${DIRECTORY}"/config/$group_router_config
        readarray intern_links < "${DIRECTORY}"/config/$group_internal_links
        readarray routinator_addrs < "${DIRECTORY}/groups/g${group_number}/routinator.txt"

        n_routers=${#routers[@]}
        n_intern_links=${#intern_links[@]}
        n_routinator_addrs=${#routinator_addrs[@]}

        # Add user to all krill configuration files
        for ((j = 0; j < n_krill_containers; j++)); do
            krill_container_data=(${krill_containers[$j]})
            n_container_data=${#krill_container_data[@]}

            # Filter out empty lines
            if [ $n_container_data -ge 2 ]; then
                krill_group_number="${krill_container_data[0]}"
                krill_container_name="${krill_container_data[1]}"
                krill_group_location="${DIRECTORY}/groups/g${krill_group_number}/krill"
                krill_config_location="${krill_group_location}/krill.conf"

                # configure user
                passwd=$(awk "\$1 == \"${group_number}\" { print \$0 }" "${DIRECTORY}/groups/passwords.txt" | cut -f 2 -d ' ')
                {
                    # Emulate a fake tty because krillc only reads input from a tty but not STDIN.
                    docker exec -i "$krill_container_name" bash -c "script -q -c 'krillc config user --id \"group${group_number}@ethz.ch\" -a \"role=readwrite\" -a \"inc_cas=group${group_number}\"' /dev/null" <<< "${passwd}" | grep "group${group_number}" | tr -d '\r'
                } >> $krill_config_location

                if [ "$group_config" == "Config" ]; then
                    group_subnet="$(subnet_group "${group_number}")"
                    echo "group ${group_number}: Adding default ROA \"${group_subnet} => ${group_number}\"..."
                    while ! docker exec $krill_container_name krillc show --ca "group${group_number}" | grep "State: active" > /dev/null; do
                        sleep 1
                    done
                    docker exec $krill_container_name krillc roas update --ca "group${group_number}" --add "${group_subnet} => ${group_number}" || true
                    echo "group ${group_number}: Default ROA added."
                fi

                # Apply ROA delta file if available for the group
                if [[ -f "${DIRECTORY}/config/roas/g${group_number}.txt" ]]; then
                    docker exec $krill_container_name krillc roas update --ca "group${group_number}" --delta "/var/krill/roas/g${group_number}.txt" || true
                fi
            fi
        done

        for ((i = 0; i < n_routers; i++)); do
            router_i=(${routers[$i]})
            rname="${router_i[0]}"
            location="${DIRECTORY}/groups/g${group_number}/${rname}/config/conf_rpki.sh"
            echo "#!/usr/bin/vtysh -f" > "${location}"
            chmod +x "${location}"

            # Configure rpki cache servers with port 3323
            {
                echo "rpki"
                echo "rpki reset"
                echo "rpki polling_period 60"
                for ((j = 0; j < n_routinator_addrs; j++)); do
                    echo "rpki cache ${routinator_addrs[$j]%$'\n'} 3323 pref ${j+1}"
                done
                echo "exit"
            } >> "${location}"
        done
    fi
done

# Restart all krill daemons
for ((j = 0; j < n_krill_containers; j++)); do
    container_data=(${krill_containers[$j]})
    n_container_data=${#container_data[@]}

    # Filter out empty lines
    if [ $n_container_data -ge 2 ]; then
        group_number="${container_data[0]}"
        container_name="${container_data[1]}"

        docker exec $container_name bash -c "kill -3 \$(cat /var/run/krill.pid)"
    fi
    wait_if_n_tasks_are_running
done

wait

# for every connection in ./config/aslevel_links.txt
# configure the route-maps
# TODO: use parallel external links files
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
        location="${DIRECTORY}/groups/g${grp_1}/${router_grp_1}/config/conf_rpki.sh"

        {
            # Set highest local preference where rpki validation returns a valid state
            echo "route-map IXP_IN_${grp_2} permit 4"
            echo "match rpki valid"
            echo "set community $grp_1:20"
            echo "set local-preference 150"
            echo "exit"
            # Drop all announcements where rpki validation returns an invalid state
            echo "route-map IXP_IN_${grp_2} deny 8"
            echo "match rpki invalid"
            echo "exit"
            # All announcements where rpki validation returns notfound get
            # a lower local-preference.
            echo "route-map IXP_IN_${grp_2} permit 6"
            echo "match rpki notfound"
            echo "set community $grp_1:20"
            echo "set local-preference 40"
            echo "exit"
        } >> "${location}"
    else
        subnet="${row_i[9]}"

        if [ "$subnet" != "N/A" ]; then
            subnet1=${subnet%????}${grp_1}/24
            subnet2=${subnet%????}${grp_2}/24
        else
            subnet1="$(subnet_router_router_extern $grp_1 $grp_2)"
            subnet2="$(subnet_router_router_extern $grp_2 $grp_1)"
        fi

        location1="${DIRECTORY}/groups/g${grp_1}/${router_grp_1}/config/conf_rpki.sh"
        {
            # Set highest local preference where rpki validation returns a valid state
            echo "route-map LOCAL_PREF_IN_${grp_2} permit 4"
            echo "match rpki valid"
            if [ $relation_grp_1 == 'Provider' ]; then
                echo "set community $grp_1:10"
                echo "set local-preference 200"
            elif [ $relation_grp_1 == 'Customer' ]; then
                echo "set community $grp_1:30"
                echo "set local-preference 120"
            elif [ $relation_grp_1 == 'Peer' ]; then
                echo "set community $grp_1:20"
                echo "set local-preference 150"
            fi
            echo "exit"
            # Drop all announcements where rpki validation returns an invalid state
            echo "route-map LOCAL_PREF_IN_${grp_2} deny 8"
            echo "match rpki invalid"
            echo "exit"
            # All announcements where rpki validation returns notfound get
            # a lower local-preference.
            echo "route-map LOCAL_PREF_IN_${grp_2} permit 6"
            echo "match rpki notfound"
            if [ $relation_grp_1 == 'Provider' ]; then
                echo "set community $grp_1:10"
                echo "set local-preference 90"
            elif [ $relation_grp_1 == 'Customer' ]; then
                echo "set community $grp_1:30"
                echo "set local-preference 10"
            elif [ $relation_grp_1 == 'Peer' ]; then
                echo "set community $grp_1:20"
                echo "set local-preference 40"
            fi
            echo "exit"
        } >> "${location1}"

        location2="${DIRECTORY}/groups/g${grp_2}/${router_grp_2}/config/conf_rpki.sh"
        {
            # Set highest local preference where rpki validation returns a valid state
            echo "route-map LOCAL_PREF_IN_${grp_1} permit 4"
            echo "match rpki valid"
            if [ $relation_grp_2 == 'Provider' ]; then
                echo "set community $grp_2:10"
                echo "set local-preference 200"
            elif [ $relation_grp_2 == 'Customer' ]; then
                echo "set community $grp_2:30"
                echo "set local-preference 120"
            elif [ $relation_grp_2 == 'Peer' ]; then
                echo "set community $grp_2:20"
                echo "set local-preference 150"
            fi
            echo "exit"
            # Drop all announcements where rpki validation returns an invalid state
            echo "route-map LOCAL_PREF_IN_${grp_1} deny 8"
            echo "match rpki invalid"
            echo "exit"
            # All announcements where rpki validation returns notfound get
            # a lower local-preference.
            echo "route-map LOCAL_PREF_IN_${grp_1} permit 6"
            echo "match rpki notfound"
            if [ $relation_grp_2 == 'Provider' ]; then
                echo "set community $grp_2:10"
                echo "set local-preference 90"
            elif [ $relation_grp_2 == 'Customer' ]; then
                echo "set community $grp_2:30"
                echo "set local-preference 10"
            elif [ $relation_grp_2 == 'Peer' ]; then
                echo "set community $grp_2:20"
                echo "set local-preference 40"
            fi
            echo "exit"
        } >> "${location2}"
    fi
done

wait

for ((k = 0; k < group_numbers; k++)); do
    group_k=(${groups[$k]})
    group_number="${group_k[0]}"
    group_as="${group_k[1]}"
    group_config="${group_k[2]}"
    group_router_config="${group_k[3]}"
    group_internal_links="${group_k[4]}"

    if [ "${group_as}" != "IXP" ]; then
        readarray routers < "${DIRECTORY}"/config/$group_router_config
        readarray intern_links < "${DIRECTORY}"/config/$group_internal_links
        readarray routinator_addrs < "${DIRECTORY}/groups/g${group_number}/routinator.txt"

        n_routers=${#routers[@]}
        n_intern_links=${#intern_links[@]}
        n_routinator_addrs=${#routinator_addrs[@]}

        for ((i = 0; i < n_routers; i++)); do
            router_i=(${routers[$i]})
            rname="${router_i[0]}"
            location="${DIRECTORY}/groups/g${group_number}/${rname}/config/conf_rpki.sh"

            if [ "$group_config" == "Config" ]; then
                if [[ $n_routinator_addrs -eq 0 ]]; then
                    echo "WARN: Group ${group_number} has no routinator instance! Skip RPKI router configuration."
                else
                    docker cp "${location}" "${group_number}_${rname}router":/home/rpki.conf > /dev/null
                    docker exec -d "${group_number}_${rname}router" ./home/rpki.conf &
                fi
            fi
        done
    fi
done

wait
