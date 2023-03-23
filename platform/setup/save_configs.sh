#!/bin/bash
#
# creates a goto.sh script for every group ssh container

set -o errexit
set -o pipefail
set -o nounset

DIRECTORY="$1"
source "${DIRECTORY}"/config/subnet_config.sh


# read configs
readarray groups < "${DIRECTORY}"/config/AS_config.txt

n_groups=${#groups[@]}

for ((k=0;k<n_groups;k++)); do
    group_k=(${groups[$k]})
    group_number="${group_k[0]}"
    group_as="${group_k[1]}"
    group_config="${group_k[2]}"
    group_router_config="${group_k[3]}"
    group_internal_links="${group_k[4]}"
    group_layer2_switches="${group_k[5]}"
    group_layer2_hosts="${group_k[6]}"
    group_layer2_links="${group_k[7]}"
    file_loc="${DIRECTORY}"/groups/g"${group_number}"/save_configs.sh
    restore_loc="${DIRECTORY}"/groups/g"${group_number}"/restore_configs.sh
    restart_ospdf="${DIRECTORY}"/groups/g"${group_number}"/restart_ospfd.sh

    if [ "${group_as}" != "IXP" ];then
        touch $file_loc
        chmod 0755 $file_loc
        readarray routers < "${DIRECTORY}"/config/$group_router_config
        readarray l2_switches < "${DIRECTORY}"/config/$group_layer2_switches
        readarray l2_hosts < "${DIRECTORY}"/config/$group_layer2_hosts
        readarray l2_links < "${DIRECTORY}"/config/$group_layer2_links
        n_routers=${#routers[@]}
        n_l2_switches=${#l2_switches[@]}
        n_l2_hosts=${#l2_hosts[@]}
        n_l2_links=${#l2_links[@]}

        l2_rname="-"
        echo "#!/bin/bash" > $file_loc
        echo "" >> $file_loc
        echo 'dirname=configs_${1:-$(date +%m-%d-%Y_%H-%M-%S)}' >> $file_loc
        echo "mkdir -p \$dirname" >> $file_loc
        echo "" >> $file_loc
        echo '# Arguments: filename, subnet, command' >> $file_loc
        echo 'save() { ssh -t -o StrictHostKeyChecking=no root@"${2%???}" ${@:3} >> $1 ; }' >> $file_loc
        echo "" >> $file_loc
        cp "${DIRECTORY}"/setup/restore_configs.sh "${restore_loc}"
        cp "${DIRECTORY}"/setup/restart_ospfd.sh "${restart_ospdf}"


        declare -A l2_id
        declare -A l2_cur

        for ((i=0;i<n_routers;i++)); do
            router_i=(${routers[$i]})
            rname="${router_i[0]}"
            property1="${router_i[1]}"
            property2="${router_i[2]}"
            l2_name=$(echo $property2 | cut -d ':' -f 1 | cut -f 2 -d '-')
            l2_id[$l2_name]=1000000
            l2_cur[$l2_name]=0
        done

        # Routers and hosts.
        for ((i=0;i<n_routers;i++)); do
            router_i=(${routers[$i]})
            rname="${router_i[0]}"
            property1="${router_i[1]}"
            property2="${router_i[2]}"
            rcmd="${router_i[3]}"
            l2_name=$(echo $property2 | cut -d ':' -f 1 | cut -f 2 -d '-')
            subnet_router=$(subnet_sshContainer_groupContainer "${group_number}" "${i}" -1  "router")
            subnet_host=$(subnet_sshContainer_groupContainer "${group_number}" "${i}" -1  "host")
            savedir="\${dirname}/$rname"

            if [[ ${l2_id[$l2_name]} == 1000000 ]]; then
                l2_id[$l2_name]=$i
            fi

            echo "# ${rname}" >> $file_loc
            echo "mkdir -p $savedir" >> $file_loc

            # Router
            if [ "${rcmd}" == "vtysh" ]; then  # vtysh is already the command.
                echo "save $savedir/router.conf     $subnet_router -- -c 'sh run'" >> $file_loc
            elif [ "${rcmd}" == "linux" ]; then
                # If we have linux access, we may also configure tunnels, so store that output.
                echo "save $savedir/router.conf     $subnet_router \"vtysh -c 'sh run'\"" >> $file_loc
                echo "save $savedir/router.tunnels  $subnet_router \"ip tunnel show\"" >> $file_loc
            fi

            # Host
            echo "save $savedir/host.ip         $subnet_host \"ip addr\"" >> $file_loc
            echo "save $savedir/host.route      $subnet_host \"ip route\"" >> $file_loc
            echo "save $savedir/host.route6     $subnet_host \"ip -6 route\"" >> $file_loc

            # If the host runs routinator, save routinator cache.
            htype=$(echo $property2 | cut -d ':' -f 1)
            dname=$(echo $property2 | cut -d ':' -f 2)
            if [[ ! -z "${dname}" ]]; then
                if [[ "${htype}" == *"routinator"* ]]; then
                    echo "save $savedir/host.rpki_cache $subnet_host \"routinator update ; tar -cz /root/.rpki-cache/repository\"" >> $file_loc
                fi
            fi
            
            # TODO: Check whether this needs an update.
            # build restore_configs.sh and restart_ospfd.sh
            echo 'if [[ "$router_name" == "'"$rname"'" || $router_name == "all" ]]; then' | tee -a "${restore_loc}" >> ${restart_ospdf}
            echo "  subnet=""$(subnet_sshContainer_groupContainer "${group_number}" "${i}" -1  "router")" | tee -a "${restore_loc}" >> ${restart_ospdf}
            echo '  main "$subnet" "'"${rname}"'" "'"${rcmd}"'"' | tee -a "${restore_loc}" >> ${restart_ospdf}
            echo "fi" | tee -a "${restore_loc}" >> ${restart_ospdf}
        done

        for ((l=0;l<n_l2_switches;l++)); do
            switch_l=(${l2_switches[$l]})
            l2_name="${switch_l[0]}"
            sname="${switch_l[1]}"
            subnet=$(subnet_sshContainer_groupContainer "${group_number}" "${l2_id[$l2_name]}" "${l2_cur[$l2_name]}" "L2")
            savedir="\${dirname}/$sname"

            echo "# ${sname}" >> $file_loc
            echo "mkdir -p $savedir" >> $file_loc
            echo "save $savedir/switch.db $subnet \"ovsdb-client backup\"" >> $file_loc

            l2_cur[$l2_name]=$((${l2_cur[$l2_name]}+1))
        done

        for ((l=0;l<n_l2_hosts;l++)); do
            host_l=(${l2_hosts[$l]})
            hname="${host_l[0]}"
            if [[ "$hname" != *VPN* ]];then
                l2_name="${host_l[2]}"
                subnet=$(subnet_sshContainer_groupContainer "${group_number}" "${l2_id[$l2_name]}" "${l2_cur[$l2_name]}" "L2")
                savedir="\${dirname}/${hname}"

                echo "# ${hname}" >> $file_loc
                echo "mkdir -p $savedir" >> $file_loc
                echo "save $savedir/host.ip     $subnet \"ip addr\"" >> $file_loc
                echo "save $savedir/host.route  $subnet \"ip route\"" >> $file_loc
                echo "save $savedir/host.route6 $subnet \"ip -6 route\"" >> $file_loc

                l2_cur[$l2_name]=$((${l2_cur[$l2_name]}+1))
            fi
        done

    fi

    echo "" >> $file_loc
    echo "tar -czf \${dirname}.tar.gz \${dirname}/*" >> $file_loc
    echo "echo \"Download the archive file:\"" >> $file_loc
    echo "echo \"    scp -P $((2000 + ${group_number})) root@duvel.ethz.ch:\${dirname}.tar.gz .\"" >> $file_loc
    echo "echo \"Overwrite the config folder in the current directory:\"" >> $file_loc
    echo "echo \"    scp -r -P $((2000 + ${group_number})) root@duvel.ethz.ch:\${dirname} config\"" >> $file_loc
done
