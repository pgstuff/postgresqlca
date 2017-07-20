#! /bin/bash

set -eu -o pipefail
script_root=$(dirname $(readlink -f "$0"))

if [ -z ${PGDATA-} ]; then
    echo "Set PGDATA."
    exit 2
elif [ ! -d ${PGDATA-} ]; then
    echo "Invalid PGDATA."
    exit 2
fi

pgdata_owner=$(stat -c '%U' "$PGDATA")

if [ "$pgdata_owner" == "$(whoami)" ]; then
    ssl_dir="$PGDATA/ssl"
    ca_template_dir="$PGDATA/ssl/cas/ca_template"
fi

if [ -e "$ssl_dir" ]; then
    echo "The SSL directory (\"${ssl_dir}\") exists." >&2
    exit 2
fi

cp -r "$script_root/ssl" "$ssl_dir"
cp -r "$script_root/ca_template" "$ca_template_dir"

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
    echo "$server_key_pass" | openssl aes-256-cbc -salt -a -e -k "$ssl_key_pass" -out "$ssl_dir/var/server_key_pass"
fi

"$ssl_dir/bin/create_server_key" "$(hostname)"
"$ssl_dir/bin/create_server_cert_sign_req" "$(hostname)"
"$ssl_dir/bin/sign_server_cert_req" "$(hostname)"
"$ssl_dir/bin/install_key_server"

if [ -z "${client_key_pass-}" ]; then
    client_key_pass=$(mkpasswd -l 32 -d 4 -c 4 -C 4 -s 4)
    echo "$client_key_pass" | openssl aes-256-cbc -salt -a -e -k "$ssl_key_pass" -out "$ssl_dir/var/client_key_pass"
fi

"$ssl_dir/bin/create_client_key" "$(whoami)"
"$ssl_dir/bin/create_client_cert_sign_req" "$(whoami)"
"$ssl_dir/bin/sign_client_cert_req" "$(whoami)"
"$ssl_dir/bin/install_key_client"
