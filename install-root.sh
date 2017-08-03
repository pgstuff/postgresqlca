#! /bin/bash

set -euo pipefail
shopt -s failglob

script_root=$(dirname "$(readlink -f "$0")")
pg_config_dir=${PGDATA-}
run_as_user=postgres
required_group=postgres

parsed_args=$(getopt -o "d:u:g:h" -l "datadirectory:,user:,group:,help" -n "$(basename $0)" -- "$@")
eval set -- "$parsed_args"
while [[ $# -gt 1 ]]; do
    case "$1" in
        -d|--datadirectory)
            pg_config_dir=$2
            shift
        ;;
        -u|--user)
            run_as_user=$2
            shift
        ;;
        -g|--group)
            required_group=$2
            shift
        ;;
        -h|--help)
            cat <<EOF
Usage: $(basename "$0") [OPTION]...
Installs SSL certificate management tools for PostgreSQL.  Run as root.

  -d, --datadirectory=PATH   Specify the path to \$PGDATA
  -u, --user                 Specify the PostgreSQL user
  -g, --group                Specify the group that can run the sudo rules
  -h, --help                 Display this help text
EOF
            exit
        ;;
        *)
            exit 2
        ;;
    esac
    shift
done

if [ -z ${pg_config_dir-} ]; then
    echo "Set PGDATA." >&2
    exit 2
elif [ ! -d ${pg_config_dir-} ]; then
    echo "Invalid PGDATA." >&2
    exit 2
fi

cp "$script_root/root/usr/local/bin/pg_package_key_client" /usr/local/bin
cp "$script_root/root/etc/sudoers.d/postgresqlca" /etc/sudoers.d

sed -i -e 's*PG_DATA_DIR_PLACEHOLDER*'"${pg_config_dir}"'*' /usr/local/bin/pg_package_key_client
sed -i -e 's*PG_RUN_AS_USER_PLACEHOLDER*'"${run_as_user}"'*' /usr/local/bin/pg_package_key_client
sed -i -e 's*PG_REQUIRED_GROUP_PLACEHOLDER*'"${required_group}"'*' /etc/sudoers.d/postgresqlca

chmod 440 /etc/sudoers.d/postgresqlca

sudo_ca_path="/etc/sudoers.d/postgresqlca$(echo "${pg_config_dir}" | tr '/' '-')"
cat > "$sudo_ca_path" <<EOF
%${required_group} ALL=(${run_as_user}) $pg_config_dir/ssl/bin/create_cert_rev_list_client_intermediate
%${required_group} ALL=(${run_as_user}) $pg_config_dir/ssl/bin/create_cert_rev_list_client_root
%${required_group} ALL=(${run_as_user}) $pg_config_dir/ssl/bin/create_cert_rev_list_server_intermediate
%${required_group} ALL=(${run_as_user}) $pg_config_dir/ssl/bin/create_cert_rev_list_server_root
%${required_group} ALL=(${run_as_user}) $pg_config_dir/ssl/bin/create_cert_sign_req_client
%${required_group} ALL=(${run_as_user}) $pg_config_dir/ssl/bin/create_cert_sign_req_server
%${required_group} ALL=(${run_as_user}) $pg_config_dir/ssl/bin/create_key_client
%${required_group} ALL=(${run_as_user}) $pg_config_dir/ssl/bin/create_key_server
%${required_group} ALL=(${run_as_user}) $pg_config_dir/ssl/bin/install_ca_client_intermediate
%${required_group} ALL=(${run_as_user}) $pg_config_dir/ssl/bin/install_ca_client_root
%${required_group} ALL=(${run_as_user}) $pg_config_dir/ssl/bin/install_ca_client_to_server
%${required_group} ALL=(${run_as_user}) $pg_config_dir/ssl/bin/install_ca_server_intermediate
%${required_group} ALL=(${run_as_user}) $pg_config_dir/ssl/bin/install_ca_server_root
%${required_group} ALL=(${run_as_user}) $pg_config_dir/ssl/bin/install_cert_users_group
%${required_group} ALL=(${run_as_user}) $pg_config_dir/ssl/bin/install_crl_client_to_server
%${required_group} ALL=(${run_as_user}) $pg_config_dir/ssl/bin/install_key_client
%${required_group} ALL=(${run_as_user}) $pg_config_dir/ssl/bin/install_key_server
%${required_group} ALL=(${run_as_user}) $pg_config_dir/ssl/bin/list_certs_client
%${required_group} ALL=(${run_as_user}) $pg_config_dir/ssl/bin/package_key_client
%${required_group} ALL=(${run_as_user}) $pg_config_dir/ssl/bin/revoke_cert_client
%${required_group} ALL=(${run_as_user}) $pg_config_dir/ssl/bin/send_key_email_client
%${required_group} ALL=(${run_as_user}) $pg_config_dir/ssl/bin/send_key_ssh_client
%${required_group} ALL=(${run_as_user}) $pg_config_dir/ssl/bin/server_reload
%${required_group} ALL=(${run_as_user}) $pg_config_dir/ssl/bin/sign_cert_req_client
%${required_group} ALL=(${run_as_user}) $pg_config_dir/ssl/bin/sign_cert_req_server
%${required_group} ALL=(${run_as_user}) $pg_config_dir/ssl/bin/sign_intermediate_ca_client
%${required_group} ALL=(${run_as_user}) $pg_config_dir/ssl/bin/sign_intermediate_ca_server
EOF
chmod 440 "$sudo_ca_path"
