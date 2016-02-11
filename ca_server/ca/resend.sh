#! /bin/bash

set -e
set -u

# Change to the directory that this script is in.
cd "$(dirname $(readlink -f "$0"))"

intermediateCaName=$(basename "$(pwd)")

dialogBackTitle="Resend Certificate Tool - $intermediateCaName"

source settings.conf

clientCaName=$(basename "$clientIntermediateCaPath")

if [ "$intermediateCaName" != "$clientCaName" ]; then
    echo "The resend tool only works for client certificates." 1>&2
    exit 2
fi

set +e
exec 3>&1
exec 4>&1
reply=$(cat index.txt 0>&4 | grep '^V' | sed 's/\/C=.*\/O=[^/]*//' | awk -F "\t" '{ printf $4 "\0" $6 "\0" "Expires "$2 "\0" }' | xargs -0 dialog --input-fd 4 --colors --keep-tite --backtitle "$dialogBackTitle" --title "Select Certificate to Resend" --item-help --default-item "$(cat serial.old)" --menu "Select a certificate to resend." 0 0 0 2>&1 1>&3)
returnCode=$?
exec 3>&-
exec 4>&-
set -e

if [ $returnCode -ne 0 ]; then
    exit 1
fi

filePath="newcerts/$reply.pem"

function getHeaderLine() {
    local headerName=$1
    openssl asn1parse -in "$filePath" | sed '/:intermediate/,$!d' | awk '/OBJECT/ && /:'"$headerName"'/ {print NR};'
}

function getAsnValueByHeaderLine() {
    local headerLineNumber=$1
    openssl asn1parse -in "$filePath" | sed '/:intermediate/,$!d' | head -n $(echo "$headerLineNumber" + 1 | bc) | tail -1 | cut -d : -f 4
}

function getAsnRequiredValue() {
    local headerName=$1

    local headerLineNumber=$(getHeaderLine "$headerName")

    if [ -z "$headerLineNumber" ]; then
        echo "$headerName is missing."
        exit 2
    fi

    getAsnValueByHeaderLine "$headerLineNumber"
}

commonNameValue=$(getAsnRequiredValue "commonName")
emailAddressValue=$(getAsnRequiredValue "emailAddress")

set +e
exec 3>&1
exec 4>&1
reply=$(dialog --colors --keep-tite --backtitle "$dialogBackTitle" --title "Confirm Certificate Resend" --yesno \
"Do you want to resend the certificate for user \"$commonNameValue\" and mail it to \"$emailAddressValue\"?" 0 0 2>&1 1>&3)
returnCode=$?
exec 3>&-
exec 4>&-
set -e

if [ $returnCode -ne 0 ]; then
    exit 1
fi


tempPath=$(mktemp -d /dev/shm/tmp.XXXXXXXXXX)
clientCertPath=${tempPath}/postgresql.crt
trustCertPath=${tempPath}/root.crt
certRevokedListPath=${tempPath}/root.crl

cp "$filePath" "$clientCertPath"
openssl verify -CAfile certs/ca-chain.cert.pem "$clientCertPath"
cp "certs/${serverCaName}-chain.cert.pem" "$trustCertPath"
#cp "certs/${rootCaName}.cert.pem" "$trustCertPath"
cp "crl/${serverCaName}.crl.pem" "$certRevokedListPath"

disableCrlRemove="x"
if [ "$disableCrl" -ne 0 ]; then
    rm "$certRevokedListPath"
    disableCrlRemove=""
fi

cd "$tempPath"
zip -9q postgresql.zip *

sed "s/USER_NAME_PLACEHOLDER/$commonNameValue/" << 'EOF' | sed "/${disableCrlRemove}root.crl/d" | mail -s "Client Certificate for PostgreSQL" -r "$(grep "^${SUDO_USER-$USER}:" /etc/passwd | cut -d : -f 5) <${SUDO_USER-$USER}@$emailDomain>" -a postgresql.zip "$emailAddressValue"
Your prior certificate is attached to this e-mail.  It is good for all PostgreSQL servers that are configured to use certificates and has an account named "USER_NAME_PLACEHOLDER".

Follow the instructions for your operating system:

Windows:

1) Save the attached .zip file.

2) Browse to your %appdata% folder.

3) Browse to the folder postgresql.  If it does not exist, then follow the instructions to create another certificate request.

4) Extract the contents of the .zip file into the postgresql folder.

5) Ensure that the key file (not the certificate request file) that you generated your certificate request with is in this folder and is named postgresql.key.

6) You should now have have the following files in this folder:

* postgresql.crt
* postgresql.key
* root.crl
* root.crt
EOF

cd /tmp
rm -Rf "$tempPath"

echo "The certificate (and supporting files) was e-mailed to $emailAddressValue."
