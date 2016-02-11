#! /bin/bash

set -e
set -u

# See https://jamielinux.com/docs/openssl-certificate-authority/introduction.html
# & http://permalink.gmane.org/gmane.comp.db.postgresql.devel.general/202317

# Change to the directory that this script is in.
cd "$(dirname $(readlink -f "$0"))"

source ca_server/ca/settings.conf

if [ -e "$serverRootCaPath" ] || [ -e "$clientRootCaPath" ]; then
    echo "Root CA already exists.  Install aborted." 1>&2
    exit 2
fi

if [ -e "$serverIntermediateCaPath" ] || [ -e "$clientIntermediateCaPath" ]; then
    echo "Intermediate CA already exists.  Install aborted." 1>&2
    exit 2
fi

serverRootCaName=$(basename "$serverRootCaPath")
if [ "$serverRootCaPath" != "$clientRootCaPath" ]; then
    clientRootCaName=$(basename "$clientRootCaPath")
fi
serverIntermediateCaName=$(basename "$serverIntermediateCaPath")
clientIntermediateCaName=$(basename "$clientIntermediateCaPath")

rm -Rf "$serverRootCaPath"
if [ "$serverRootCaPath" != "$clientRootCaPath" ]; then
    rm -Rf "$clientRootCaPath"
fi
rm -Rf "$serverIntermediateCaPath"
rm -Rf "$clientIntermediateCaPath"

if [ ! -e "$intermediateCaUserHome" ]; then
    useradd --user-group "$intermediateCaUserName"
    chmod g+rx "$intermediateCaUserHome"
    if [ -n "${SUDO_USER-}" ]; then
        usermod -a -G "$intermediateCaUserName" "${SUDO_USER-}"
    fi
fi

serverRootPass=$(mkpasswd -l 32 -d 5 -c 5 -C 5 -s 5)
if [ "$serverRootCaPath" != "$clientRootCaPath" ]; then
    clientRootPass=$(mkpasswd -l 32 -d 5 -c 5 -C 5 -s 5)
fi
serverIntermediatePass=$(mkpasswd -l 24 -d 3 -c 3 -C 3 -s 3)
clientIntermediatePass=$(mkpasswd -l 24 -d 3 -c 3 -C 3 -s 3)

cp -pR ca_server/ca "$serverRootCaPath"
rm "$serverRootCaPath"/*.sh
chown -R root:root "$serverRootCaPath"
if [ "$serverRootCaPath" != "$clientRootCaPath" ]; then
    cp -pR ca_server/ca "$clientRootCaPath"
    rm "$clientRootCaPath"/*.sh
    chown -R root:root "$clientRootCaPath"
fi
cp -pR ca_server/ca "$serverIntermediateCaPath"
cp -pR ca_server/ca "$clientIntermediateCaPath"
chown -R root:root "$serverIntermediateCaPath" "$clientIntermediateCaPath"

function installConfigSettings () {
    local configPath=$1
    local caName=$2
    local caHome=$3
    local caPolicy=$4

    sed -i "s/CA_NAME_PLACEHOLDER/$caName/" "$configPath"
    sed -i "s/CA_POLICY_PLACEHOLDER/$caPolicy/" "$configPath"
    sed -i "s/CA_HOME_PLACEHOLDER/$(echo "$caHome" | sed 's/\//\\\//g')/" "$configPath"
    sed -i "s/COUNTRYNAME_PLACEHOLDER/$countryName/" "$configPath"
    sed -i "s/STATEORPROVINCENAME_PLACEHOLDER/$stateOrProvinceName/" "$configPath"
    sed -i "s/LOCALITYNAME_PLACEHOLDER/$localityName/" "$configPath"
    sed -i "s/ORGANIZATIONNAME_PLACEHOLDER/$organizationName/" "$configPath"
    sed -i "s/ORGANIZATIONALUNITNAME_PLACEHOLDER/$organizationalUnitName/" "$configPath"
    sed -i "s/SERVICEEMAILADDRESS_PLACEHOLDER/$serviceEmailAddress/" "$configPath"
    sed -i "s/MESSAGEDIGEST_PLACEHOLDER/$messageDigest/" "$configPath"
    sed -i "s/CERTLIFETIMEDAYS_PLACEHOLDER/$certLifetimeDays/" "$configPath"
    sed -i "s/CLIENTSERVERKEYLEN_PLACEHOLDER/$clientServerKeyLen/" "$configPath"
    sed -i "s/CAKEYLEN_PLACEHOLDER/$caKeyLen/" "$configPath"
}

installConfigSettings "$serverRootCaPath/openssl.cnf" "$serverRootCaName" "$rootCaUserHome" "policy_strict"
if [ "$serverRootCaPath" != "$clientRootCaPath" ]; then
    installConfigSettings "$clientRootCaPath/openssl.cnf" "$clientRootCaName" "$rootCaUserHome" "policy_strict"
fi
installConfigSettings "$serverIntermediateCaPath/openssl.cnf" "$serverIntermediateCaName" "$intermediateCaUserHome" "policy_loose"
installConfigSettings "$clientIntermediateCaPath/openssl.cnf" "$clientIntermediateCaName" "$intermediateCaUserHome" "policy_loose"

function installRoot() {
    local rootCaPath=$1
    local rootPass=$2

    local rootCaName=$(basename "$rootCaPath")

    cd "$rootCaPath"

    echo "Create the ${rootCaName} key"
    exec 3<<<"$rootPass"
    openssl genrsa -aes256 -passout fd:3 -out "private/$rootCaName.key.pem" "$caKeyLen"
    chmod 600 "private/$rootCaName.key.pem"

    echo "Create the ${rootCaName} certificate signing request"
    exec 3<<<"$rootPass"
    openssl req -config openssl.cnf -key "private/$rootCaName.key.pem" -new -x509 -days "$certLifetimeDays" -$messageDigest -passin fd:3 -extensions v3_ca -subj "$("$serverIntermediateCaPath/getsubject.sh" "$rootCaName")" -out "certs/$rootCaName.cert.pem"
    chmod 644 "certs/$rootCaName.cert.pem"

    echo "Verify the ${rootCaName} certificate"
    openssl x509 -noout -text -in "certs/$rootCaName.cert.pem"
}

installRoot "$serverRootCaPath" "$serverRootPass"
if [ "$serverRootCaPath" != "$clientRootCaPath" ]; then
    installRoot "$clientRootCaPath" "$clientRootPass"
fi

function installIntermediate() {
    local intermediateCaName=$1
    local intermediateCaPath=$2
    local intermediateCaPass=$3
    local rootCaPath=$4
    local rootPass=$5

    local rootCaName=$(basename "$rootCaPath")

    cd "$intermediateCaPath"

    echo "Create the ${intermediateCaName} key"
    exec 3<<<"$intermediateCaPass"
    openssl genrsa -aes256 -passout fd:3 -out "private/${intermediateCaName}.key.pem" "$caKeyLen"
    chmod 600 "private/${intermediateCaName}.key.pem"

    echo "Create the ${intermediateCaName} certificate signing request"
    exec 3<<<"$intermediateCaPass"
    openssl req -config openssl.cnf -new -$messageDigest -passin fd:3 -key "private/${intermediateCaName}.key.pem" -subj "$("$intermediateCaPath/getsubject.sh" "${intermediateCaName}")" -out "csr/${intermediateCaName}.csr.pem"

    cd "$rootCaPath"

    echo "Sign the ${intermediateCaName} certificate"
    exec 3<<<"$rootPass"
    openssl ca -config openssl.cnf -extensions v3_intermediate_ca -days "$certLifetimeDays" -notext -md $messageDigest -passin fd:3 -batch -in "$intermediateCaPath/csr/${intermediateCaName}.csr.pem" -out "$intermediateCaPath/certs/${intermediateCaName}.cert.pem"

    echo "Verify the ${intermediateCaName} certificate"
    openssl x509 -noout -text -in "$intermediateCaPath/certs/${intermediateCaName}.cert.pem"

    openssl verify -CAfile "certs/$rootCaName.cert.pem" "$intermediateCaPath/certs/${intermediateCaName}.cert.pem"

    echo "Create the ${intermediateCaName} chain file"

    cat "$intermediateCaPath/certs/${intermediateCaName}.cert.pem" "certs/$rootCaName.cert.pem" > "$intermediateCaPath/certs/${intermediateCaName}-chain.cert.pem"

    chmod 644 "$intermediateCaPath/certs/${intermediateCaName}-chain.cert.pem"

    echo "Create the ${intermediateCaName} CRL"

    cd "$intermediateCaPath"

    exec 3<<<"$intermediateCaPass"
    openssl ca -config openssl.cnf -gencrl -passin fd:3 -out "crl/${intermediateCaName}.crl.pem"

    openssl crl -in "crl/${intermediateCaName}.crl.pem" -noout -text

    cp "$rootCaPath/certs/${rootCaName}.cert.pem" -p "certs/${rootCaName}.cert.pem"

    chown -R $intermediateCaUserName:$intermediateCaUserName "$intermediateCaPath"
}

installIntermediate "$serverIntermediateCaName" "$serverIntermediateCaPath" "$serverIntermediatePass" "$serverRootCaPath" "$serverRootPass"
installIntermediate "$clientIntermediateCaName" "$clientIntermediateCaPath" "$clientIntermediatePass" "${clientRootCaPath-$serverRootCaPath}" "${clientRootPass-$serverRootPass}"

cp -p "$serverIntermediateCaPath/certs/${serverIntermediateCaName}.cert.pem" "$clientIntermediateCaPath/certs/${serverIntermediateCaName}.cert.pem"
cp -p "$clientIntermediateCaPath/certs/${clientIntermediateCaName}.cert.pem" "$serverIntermediateCaPath/certs/${clientIntermediateCaName}.cert.pem"
cp -p "$serverIntermediateCaPath/certs/${serverIntermediateCaName}-chain.cert.pem" "$clientIntermediateCaPath/certs/${serverIntermediateCaName}-chain.cert.pem"
cp -p "$clientIntermediateCaPath/certs/${clientIntermediateCaName}-chain.cert.pem" "$serverIntermediateCaPath/certs/${clientIntermediateCaName}-chain.cert.pem"
cp -p "$serverIntermediateCaPath/crl/${serverIntermediateCaName}.crl.pem" "$clientIntermediateCaPath/crl/${serverIntermediateCaName}.crl.pem"
cp -p "$clientIntermediateCaPath/crl/${clientIntermediateCaName}.crl.pem" "$serverIntermediateCaPath/crl/${clientIntermediateCaName}.crl.pem"

if [ "$serverRootCaPath" != "$clientRootCaPath" ]; then
    cp -p "$serverIntermediateCaPath/certs/${serverRootCaName}.cert.pem" "$clientIntermediateCaPath/certs"
    cp -p "$clientIntermediateCaPath/certs/${clientRootCaName}.cert.pem" "$serverIntermediateCaPath/certs"
fi

echo
if [ "$serverRootCaPath" != "$clientRootCaPath" ]; then
echo "Server Root CA pass phrase:          $serverRootPass"
echo "Client Root CA pass phrase:          $clientRootPass"
else
echo "Root CA pass phrase:                 $serverRootPass"
fi
echo "Server Intermediate CA pass phrase:  $serverIntermediatePass"
echo "Client Intermediate CA pass phrase:  $clientIntermediatePass"

