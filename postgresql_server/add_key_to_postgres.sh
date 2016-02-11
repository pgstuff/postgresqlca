#! /bin/sh

set -e
set -u

keyDir=$1
PGDATA=$2
clientCaName=$3
#rootCaName=$3

hostName=$(hostname)

if [ ! -e "$keyDir/$hostName-postgresql.crt" ]; then
    echo "Certificate not found."
    exit 2
fi

if [ ! -e "$PGDATA/postgresql.conf" ]; then
    echo "postgresql.conf not found."
    exit 2
fi

sslCaFileName=${clientCaName}-chain.cert.pem
#sslCaFileName=${rootCaName}.cert.pem

if [ ! -e "$sslCaFileName" ]; then
    echo "$sslCaFileName not found."
    exit 2
fi

#openssl verify -CAfile "$keyDir/${sslCaFileName}" -purpose sslserver "$keyDir/$hostName-postgresql.crt"

cp "$keyDir/$hostName-postgresql.crt" "$keyDir/$hostName-postgresql.key" "$keyDir/${sslCaFileName}" "$PGDATA"
chown postgres:postgres "$PGDATA/$hostName-postgresql.crt" "$PGDATA/$hostName-postgresql.key" "$PGDATA/${sslCaFileName}"

cp -p "$PGDATA/postgresql.conf" "$PGDATA/postgresql.conf-before_key_add~"

sed -i "s/^#ssl =/ssl =/" "$PGDATA/postgresql.conf"
sed -i "s/^#ssl_cert_file =/ssl_cert_file =/" "$PGDATA/postgresql.conf"
sed -i "s/^#ssl_key_file =/ssl_key_file =/" "$PGDATA/postgresql.conf"
sed -i "s/^#ssl_ca_file =/ssl_ca_file =/" "$PGDATA/postgresql.conf"

if [ -e "$keyDir/${clientCaName}.crl.pem" ]; then
    cp "$keyDir/${clientCaName}.crl.pem" "$PGDATA"
    chown postgres:postgres "$PGDATA/${clientCaName}.crl.pem"
    sed -i "s/#ssl_crl_file =/ssl_crl_file =/" "$PGDATA/postgresql.conf"
    sed -ri "s/(ssl_crl_file) .*$/\1 = '${clientCaName}.crl.pem'/" "$PGDATA/postgresql.conf"
else
    if [ -e "$PGDATA/${clientCaName}.crl.pem" ]; then
        rm "$PGDATA/${clientCaName}.crl.pem"
    fi
    sed -ri "s/(ssl_crl_file) .*$/\1 = 'root.crl'/" "$PGDATA/postgresql.conf"
    sed -i "s/^ssl_crl_file =/#ssl_crl_file =/" "$PGDATA/postgresql.conf"
fi

sed -ri "s/(ssl) .*$/\1 = on/" "$PGDATA/postgresql.conf"
sed -ri "s/(ssl_cert_file) .*$/\1 = '$hostName-postgresql.crt'/" "$PGDATA/postgresql.conf"
sed -ri "s/(ssl_key_file) .*$/\1 = '$hostName-postgresql.key'/" "$PGDATA/postgresql.conf"
sed -ri "s/(ssl_ca_file) .*$/\1 = '${sslCaFileName}'/" "$PGDATA/postgresql.conf"
