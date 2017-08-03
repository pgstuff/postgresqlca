#! /bin/bash

set -euo pipefail
shopt -s failglob

script_root=$(dirname "$(readlink -f "$0")")
pg_config_dir=${PGDATA-}
create_user_cert=0
interactive=0
pg_reload=0

function get_boolean() {
    case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
        1|t|true|y|yes)
            echo 1
            return
        ;;
        0|f|false|n|no)
            echo 0
            return
        ;;
    esac
    echo "Value \"$1\" is not a recognized boolean value." >&2
    exit 2
}

parsed_args=$(getopt -o "d:c:i:er:h" -l "datadirectory:,createusercert:,interactive:,editvars,reload:,help" -n "$(basename $0)" -- "$@")
eval set -- "$parsed_args"
while [[ $# -gt 1 ]]; do
    case "$1" in
        -d|--datadirectory)
            pg_config_dir=$2
            shift
        ;;
        -c|--createusercert)
            create_user_cert=$(get_boolean $2)
            shift
        ;;
        -i|--interactive)
            interactive=$(get_boolean $2)
            shift
        ;;
        -e|--editvars)
            if ! [ -x "$(command -v dialog)" ]; then
                echo 'Error: dialog is not installed.  Install the dialog package.' >&2
                exit 2
            fi
            "$script_root/ca_template/bin/edit_vars"
            exit
        ;;
        -r|--reload)
            pg_reload=$(get_boolean $2)
            shift
        ;;
        -h|--help)
            cat <<EOF
Usage: $(basename "$0") [OPTION]...
Installs SSL certificate management tools for PostgreSQL.  Run as the PostgreSQL user.

  -d, --datadirectory=PATH   Specify the path to \$PGDATA
  -c, --createusercert=BOOL  True to create a certificate for the active user after the install
  -i, --interactive=BOOL     Prompt for certificate configuration while installing
  -e, --editvars             Edit the certificate configuration before installing
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

export install_edit_vars=$interactive

exit_code=0
if [ -z ${pg_config_dir-} ]; then
    echo "Set PGDATA." >&2
    exit_code=2
elif [ ! -d ${pg_config_dir-} ]; then
    echo "Invalid PGDATA." >&2
    exit_code=2
fi
if ! [ -x "$(command -v openssl)" ]; then
    echo 'Error: openssl is not installed.' >&2
    exit_code=2
fi

if ! [ -x "$(command -v mkpasswd)" ]; then
    set_list=""
    if [ -z "${ssl_key_pass-}" ];               then set_list="$set_list ssl_key_pass"; fi
    if [ -z "${ca_server_root_pass-}" ];        then set_list="$set_list ca_server_root_pass"; fi
    if [ -z "${ca_server_intermediate_pass-}" ];then set_list="$set_list ca_server_intermediate_pass"; fi
    if [ -z "${ca_client_intermediate_pass-}" ];then set_list="$set_list ca_client_intermediate_pass"; fi
    if [ -z "${ca_client_root_pass-}" ];        then set_list="$set_list ca_client_root_pass"; fi
    if [ -z "${server_key_pass-}" ];            then set_list="$set_list server_key_pass"; fi
    if [ -z "${client_key_pass-}" ];            then set_list="$set_list client_key_pass"; fi
    if [ -n "$set_list" ]; then
        echo 'Error: mkpasswd is not installed.  Install the expect package.' >&2
        echo "You can avoid using mkpasswd if you set:$set_list"
        exit_code=2
    fi
fi
if ! [ -x "$(command -v dialog)" ]; then
    if [ "$interactive" -ne 0 ]; then
        echo 'Error: dialog is not installed.  Install the dialog package.' >&2
        echo "You can avoid using dialog if you add: -i 0"
        exit_code=2
    fi
fi
if [ $exit_code -ne 0 ]; then
    exit $exit_code
fi

pgdata_owner=$(stat -c '%U' "$pg_config_dir")

if [ "$pgdata_owner" == "$(whoami)" ]; then
    ssl_dir="$pg_config_dir/ssl"
    ca_template_dir="$pg_config_dir/ssl/cas/ca_template"
fi

if [ -e "$ssl_dir" ]; then
    echo "The SSL directory (\"${ssl_dir}\") exists." >&2
    exit 2
fi

cp -r "$script_root/ssl" "$ssl_dir"
cp -r "$script_root/ca_template" "$ca_template_dir"
find "$ca_template_dir" -name .gitignore -delete

if [ -z "${ssl_key_pass-}" ]; then
    ssl_key_pass=$(mkpasswd -l 32 -d 4 -c 4 -C 4 -s 4)
fi
echo "$ssl_key_pass" > "$ssl_dir/var/ssl_key_pass"

function install_ca() {
    ca_type=$1
    "$ssl_dir/bin/install_ca_${ca_type}_root"
    "$ssl_dir/bin/create_cert_rev_list_${ca_type}_root"
    "$ssl_dir/bin/install_ca_${ca_type}_intermediate"
    "$ssl_dir/bin/sign_intermediate_ca_${ca_type}"
    "$ssl_dir/bin/create_cert_rev_list_${ca_type}_intermediate"
}

install_ca server
install_ca client

if [ -z "${server_key_pass-}" ]; then
    server_key_pass=$(mkpasswd -l 32 -d 4 -c 4 -C 4 -s 4)
fi
echo "$server_key_pass" | openssl aes-256-cbc -salt -a -e -k "$ssl_key_pass" -out "$ssl_dir/var/server_key_pass"

"$ssl_dir/bin/create_key_server" "$(hostname)"
"$ssl_dir/bin/create_cert_sign_req_server" "$(hostname)"
"$ssl_dir/bin/sign_cert_req_server" "$(hostname)"
"$ssl_dir/bin/install_key_server"
"$ssl_dir/bin/install_ca_client_to_server"
"$ssl_dir/bin/install_crl_client_to_server"

if [ -z "${client_key_pass-}" ]; then
    client_key_pass=$(mkpasswd -l 32 -d 4 -c 4 -C 4 -s 4)
fi
echo "$client_key_pass" | openssl aes-256-cbc -salt -a -e -k "$ssl_key_pass" -out "$ssl_dir/var/client_key_pass"
if [ $create_user_cert -ne 0 ]; then
    "$ssl_dir/bin/create_key_client" "$(whoami)"
    "$ssl_dir/bin/create_cert_sign_req_client" "$(whoami)"
fi

# Install last so that the instructions are more likely to be seen.
"$ssl_dir/bin/install_cert_users_group" --datadirectory "$pg_config_dir"

if [ $create_user_cert -ne 0 ]; then
    "$ssl_dir/bin/sign_cert_req_client" "$(whoami)"
    "$ssl_dir/bin/install_key_client"
fi

base_dir="$ssl_dir"
source "$ssl_dir/var/paths.sh"
cert_users_group_name="$(cat "$ca_server_intermediate_dir/var/server_cert_users_group_name.var")"
if [ -n "$cert_users_group_name" ]; then
    "$ssl_dir/bin/server_reload" -r $pg_reload
fi
