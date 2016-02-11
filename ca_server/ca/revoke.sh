#! /bin/bash

set -e
set -u

# Change to the directory that this script is in.
cd "$(dirname $(readlink -f "$0"))"

intermediateCaName=$(basename "$(pwd)")

dialogBackTitle="Revoke Certificate Tool - $intermediateCaName"

source settings.conf

serverCaName=$(basename "$serverIntermediateCaPath")
clientCaName=$(basename "$clientIntermediateCaPath")

set +e
exec 3>&1
exec 4>&1
reply=$(cat index.txt 0>&4 | grep '^V' | sed 's/\/C=.*\/O=[^/]*//' | awk -F "\t" '{ printf $4 "\0" $6 "\0" "Expires "$2 "\0" }' | xargs -0 dialog --input-fd 4 --colors --keep-tite --backtitle "$dialogBackTitle" --title "Select Certificate to Revoke" --item-help --menu "Select a certificate to revoke." 0 0 0 2>&1 1>&3)
returnCode=$?
exec 3>&-
exec 4>&-
set -e

if [ $returnCode -ne 0 ]; then
    exit 1
fi

echo "Revoking certificate $reply:"
openssl ca -config openssl.cnf -revoke "newcerts/$reply.pem"

echo
echo "Updating the certificate revocation list:"
openssl ca -config openssl.cnf -gencrl -out "crl/${intermediateCaName}.crl.pem"
echo

if [ "$intermediateCaName" = "$serverCaName" ]; then
    if [ -e "$clientIntermediateCaPath" ]; then
        echo "Updating ${clientCaName}'s copy of the CRL."
        cp -p "crl/${serverCaName}.crl.pem" -p "$clientIntermediateCaPath/crl/${serverCaName}.crl.pem"
    else
        echo "Copy the CRL into ${clientCaName}'s crl directory."
    fi
fi

if [ "$intermediateCaName" = "$clientCaName" ]; then
    if [ -e "$serverIntermediateCaPath" ]; then
        echo "Updating ${serverCaName}'s copy of the CRL."
        cp -p "crl/${clientCaName}.crl.pem" -p "$serverIntermediateCaPath/crl/${clientCaName}.crl.pem"
    else
        echo "Copy the CRL into ${serverCaName}'s crl directory."
    fi
fi

echo
echo "Distribute the CRL at $(pwd)/crl/${intermediateCaName}.crl.pem if applicable."
if [ "$intermediateCaName" = "$clientCaName" ]; then
    echo "For example:  sudo cp $(pwd)/crl/${clientCaName}.crl.pem \$PGDATA/${clientCaName}.crl.pem"
fi
if [ "$intermediateCaName" = "$serverCaName" ]; then
    echo "For example:  cp $(pwd)/crl/${serverCaName}.crl.pem ~/.postgresql/root.crl"
fi
