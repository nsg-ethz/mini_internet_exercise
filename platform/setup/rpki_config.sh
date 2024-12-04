#!/bin/bash
#
# Generates some RPKI related configuration files.
# This is the second part of the RPKI related startup script.
#
# NOTE
# It generates the root certificate for issuing other certificates e.g. for the
# krill server. The root certificate is saved under groups/rpki/
#
# IMPORTANT!
# The configuration files are created with the assumption that only ONE krill
# server exists! For multiple krill servers (as trust anchors or delegated rpki),
# additional options have to be added to the configuration files.

set -o errexit
set -o pipefail
set -o nounset

DIRECTORY="$1"
source "${DIRECTORY}"/config/subnet_config.sh
source "${DIRECTORY}"/setup/_parallel_helper.sh

# read configs
readarray groups < "${DIRECTORY}"/config/AS_config.txt

n_groups=${#groups[@]}

# all configs are saved in groups
rpki_location="${DIRECTORY}/groups/rpki"
mkdir -p "${rpki_location}/tals"
krill_webserver_ip_links="${rpki_location}/webserver_links.sh"

# Initialize empty file
echo "#!/bin/bash" > $krill_webserver_ip_links
echo "source \"${DIRECTORY}/setup/ovs-docker.sh\"" >> $krill_webserver_ip_links
chmod +x $krill_webserver_ip_links

# Validity duration for generated certificates
EXPIRES_IN_DAYS=365

# Generate root certificate used for issuing other certificates
ISSUER="/C=CH/L=Zurich/O=ETH Zurich"
openssl req -new \
    -x509 \
    -newkey rsa:4096 \
    -sha256 \
    -nodes \
    -keyout "${rpki_location}/root.key" \
    -out "${rpki_location}/root.crt" \
    -days "${EXPIRES_IN_DAYS}" \
    -subj "${ISSUER}"

# Generate passwords for use with RPKI, SSH and VPN.
for ((j = 0; j < n_groups; j++)); do
    group_j=(${groups[$j]})
    group_number="${group_j[0]}"
    group_as="${group_j[1]}"

    if [ "${group_as}" != "IXP" ]; then
        passwd="$(openssl rand -hex 8)"
        echo "${group_number} ${passwd}" >> "${DIRECTORY}"/groups/passwords.txt
    fi
done

# Create pair of keys dedicated to allowing ssh forwarding via the ssh proxy container to the kill webserver
ssh-keygen -t rsa -b 4096 -C "krill webserver" -P "" -f "${DIRECTORY}"/groups/rpki/id_rsa_krill_webserver -q

wait

for role in "readonly" "admin"; do
    passwd="$(openssl rand -hex 8)"
    echo "${role} ${passwd}" >> "${DIRECTORY}"/groups/krill_passwords.txt
done

# Generate certificate for krill server (rpki-server.groupX)
for ((j = 0; j < n_groups; j++)); do
    group_j=(${groups[$j]})
    group_number="${group_j[0]}"
    group_as="${group_j[1]}"
    group_router_config="${group_j[3]}"
    group_internal_links="${group_j[4]}"

    touch "${DIRECTORY}/groups/g${group_number}/routinator.txt"

    if [ "${group_as}" != "IXP" ]; then
        readarray routers < "${DIRECTORY}"/config/$group_router_config
        readarray intern_links < "${DIRECTORY}"/config/$group_internal_links
        n_routers=${#routers[@]}
        n_intern_links=${#intern_links[@]}

        for ((i = 0; i < n_routers; i++)); do
            router_i=(${routers[$i]})
            rname="${router_i[0]}"
            property1="${router_i[1]}"
            property2="${router_i[2]}"
            htype=$(echo $property2 | cut -d ':' -f 1)
            dname=$(echo $property2 | cut -d ':' -f 2)

            if [[ ! -z "${dname}" ]]; then
                if [[ "${htype}" == *"routinator"* ]]; then
                    subnet="$(subnet_host_router "${group_number}" "$i" "host")"

                    echo "${subnet%/*}" >> "${DIRECTORY}/groups/g${group_number}/routinator.txt"

                    # Default exceptions file
                    {
                        echo "{"
                        echo "  \"slurmVersion\": 1,"
                        echo "  \"validationOutputFilters\": {"
                        echo "    \"prefixFilters\": [],"
                        echo "    \"bgpsecFilters\": []"
                        echo "  },"
                        echo "  \"locallyAddedAssertions\": {"
                        echo "    \"prefixAssertions\": [],"
                        echo "    \"bgpsecAssertions\": []"
                        echo "  }"
                        echo "}"
                    } > "${DIRECTORY}/groups/g${group_number}/rpki_exceptions.json"

                    # The following file contains exceptions that are useful for the autograder
                    {
                        echo "{"
                        echo "  \"slurmVersion\": 1,"
                        echo "  \"validationOutputFilters\": {"
                        echo "    \"prefixFilters\": [],"
                        echo "    \"bgpsecFilters\": []"
                        echo "  },"
                        echo "  \"locallyAddedAssertions\": {"
                        echo "    \"prefixAssertions\": [ "
                        for seqv in $(seq 1 253); do
                            echo "    { "
                            echo "      \"asn\": 10000, "
                            echo "      \"prefix\": \"200.$seqv.0.0/16\", "
                            echo "      \"maxPrefixLength\": 16, "
                            echo "      \"comment\": \"used by the autograder container\" "
                            echo "    }, "
                        done
                        echo "    { "
                        echo "      \"asn\": 10000, "
                        echo "      \"prefix\": \"200.254.0.0/16\", "
                        echo "      \"maxPrefixLength\": 16, "
                        echo "      \"comment\": \"used by the autograder container\" "
                        echo "    } "
                        echo "  ],"
                        echo "    \"bgpsecAssertions\": []"
                        echo "  }"
                        echo "}"
                    } > "${DIRECTORY}/groups/g${group_number}/rpki_exceptions_autograder.json"

                elif [[ "${htype}" == *"krill"* ]]; then
                    subnet="$(subnet_host_router "${group_number}" "$i" "host")"

                    krill_subject="/C=CH/L=Zurich/O=ETH Zurich/CN=rpki-server.group${group_number}"
                    krill_san="DNS:rpki-server.group${group_number}, DNS:rpki-server.group${group_number}:3000, DNS:rpki-server.group${group_number}:3080, DNS:host.${rname,,}.group${group_number}, DNS:localhost, IP:${subnet%/*}, IP:127.0.0.1"
                    krill_group_location="${DIRECTORY}/groups/g${group_number}/krill"

                    mkdir -p "${krill_group_location}/data"

                    # Prepare x509 Certificate extensions
                    krill_cert_extension_file="${krill_group_location}/krill.ext"
                    {
                        echo "[krill]"
                        echo "subjectAltName=${krill_san}"
                        echo "basicConstraints=CA:FALSE"
                    } >> $krill_cert_extension_file

                    openssl req -new \
                        -newkey rsa:4096 \
                        -keyout "${krill_group_location}/krill.key" \
                        -out "${krill_group_location}/krill.csr" \
                        -sha256 \
                        -nodes \
                        -subj "${krill_subject}"
                    openssl x509 \
                        -in "${krill_group_location}/krill.csr" \
                        -req \
                        -out "${krill_group_location}/krill.crt" \
                        -CA "${rpki_location}/root.crt" \
                        -CAkey "${rpki_location}/root.key" \
                        -CAcreateserial \
                        -extensions krill \
                        -extfile "${krill_cert_extension_file}" \
                        -days "${EXPIRES_IN_DAYS}"

                    cat "${krill_group_location}/krill.crt" "${krill_group_location}/krill.key" > "${krill_group_location}/krill.includesprivatekey.pem"

                    # Prepare CA setup script and krill configuration file
                    setup_location="${krill_group_location}/setup.sh"
                    krill_config_location="${krill_group_location}/krill.conf"
                    krill_auth_token_location="${krill_group_location}/krill_token.txt"

                    {
                        echo "#!/bin/bash -e"
                        echo "export KRILL_TEST=true"
                        echo "KRILL_SERVER=\"https://127.0.0.1:3000/\""
                    } > $setup_location

                    krill_auth_token=$(uuidgen)
                    echo -n $krill_auth_token > $krill_auth_token_location
                    {
                        echo "# General configuration for krill"
                        echo "ip           = \"127.0.0.1\""
                        echo "port         = 3001"
                        echo "data_dir     = \"/var/krill/data/\""
                        echo "pid_file     = \"/var/run/krill.pid\""
                        echo "repo_enabled = true"
                        echo "log_type     = \"stderr\""
                        echo "rsync_base   = \"rsync://rpki-server.group${group_number}:3000/repo/\""
                        echo "service_uri  = \"https://rpki-server.group${group_number}:3000/\""
                        echo "auth_token   = \"${krill_auth_token}\""
                        echo "bgp_risdumps_enabled = false"
                        echo "timing_roa_valid_weeks = 2"
                        echo "timing_roa_reissue_weeks_before = 1"
                        echo
                        echo "# Multi-user configuration for krill"
                        echo "auth_type    = \"config-file\""
                        echo
                        echo "[testbed]"
                        echo "rrdp_base_uri = \"https://rpki-server.group${group_number}:3000/rrdp/\""
                        echo "rsync_jail = \"rsync://rpki-server.group${group_number}:3000/repo/\""
                        echo "ta_aia = \"rsync://rpki-server.group${group_number}:3000/ta/ta.cer\""
                        echo "ta_uri = \"https://rpki-server.group${group_number}:3000/ta/ta.cer\""
                        echo
                        echo "[auth_users]"
                    } > $krill_config_location

                    for ((k = 0; k < n_groups; k++)); do
                        other_group_k=(${groups[$k]})
                        other_group_number="${other_group_k[0]}"
                        other_group_as="${other_group_k[1]}"
                        ca_name="group${other_group_number}"
                        other_group_subnet="$(subnet_group "${other_group_number}")"

                        if [ "${other_group_as}" != "IXP" ]; then
                            # Add CA for group
                            {
                                # Create CA
                                echo
                                echo "krillc add --server \$KRILL_SERVER --ca \"${ca_name}\""
                                # Register CA with local publication server
                                echo "krillc repo request --server \$KRILL_SERVER \\"
                                echo "    --ca \"${ca_name}\" > /tmp/${ca_name}_publisher_request.xml"
                                echo "krillc pubserver publishers add \\"
                                echo "    --server \$KRILL_SERVER \\"
                                echo "    --publisher \"${ca_name}\" \\"
                                echo "    --request /tmp/${ca_name}_publisher_request.xml > /tmp/${ca_name}_repository_response.xml"
                                echo "krillc repo configure --server \$KRILL_SERVER \\"
                                echo "    --ca \"${ca_name}\" \\"
                                echo "    --format text \\"
                                echo "    --response /tmp/${ca_name}_repository_response.xml"
                                # Add TA as parent of CA (CA RFC 8183 Child Request XML file)
                                echo "krillc parents request --server \$KRILL_SERVER \\"
                                echo "    --ca \"${ca_name}\" > /tmp/${ca_name}_myid.xml"
                                # As TA: add CA as child using the request file
                                echo "krillc children add --server \$KRILL_SERVER \\"
                                echo "    --ca ta \\"
                                echo "    --child \"${ca_name}\" \\"
                                echo "    --asn \"AS${other_group_number}\" \\"
                                echo "    --ipv4 \"${other_group_subnet}\" \\"
                                echo "    --request /tmp/${ca_name}_myid.xml > /tmp/${ca_name}_parent_response.xml"
                                # As CA: add TA as parent using the response file
                                echo "krillc parents add --server \$KRILL_SERVER \\"
                                echo "    --ca \"${ca_name}\" \\"
                                echo "    --parent ta \\"
                                echo "    --response /tmp/${ca_name}_parent_response.xml"
                            } >> $setup_location
                        fi
                    done
                fi
            fi
        done
    fi
done

wait
