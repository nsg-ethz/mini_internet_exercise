# This script is used to configure ASes that were originally not preconfigured (NoConfig flag)
# The Layer2 network is not configured, only the L3 network as well as the hosts

### TO UPDATE ###
# this variable is the absolute path to the platform directory.
PLATFORM_DIR=
# this variable includes all the AS number that need to be configured.
ASN_TO_CONFIGURE=
# this variable contains all the router names that need to be configured.
ROUTER_NAMES=

for group_number in ASN_TO_CONFIGURE
do
    rid=1
    # This loop should iterate over the router, starting from lower ID to higher ID.
    for router_name in ROUTER_NAMES
    do
        config_dir="$PLATFORM_DIR/groups/g${group_number}/${router_name}/config"
        for config_file in init.conf full.conf rpki.conf; do
            chmod 755 "${config_dir}/${config_file}"
            docker cp "${config_dir}/${config_file}" "${group_number}_${router_name}router":/home/ > /dev/null
            docker exec -it "${group_number}_${router_name}router" bash -c "'cat /home/${config_file} | vtysh'"
        done

        docker exec -it ${group_number}_${router_name}host ip address add ${group_number}.$((100+$rid)).0.1/24 dev ${router_name}router 
        docker exec -it ${group_number}_${router_name}host ip route add default via ${group_number}.$((100+$rid)).0.2

        rid=$(($rid+1))
        echo $group_number $router_name
    done
done
