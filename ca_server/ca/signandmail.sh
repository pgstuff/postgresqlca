#! /bin/bash

set -e
set -u

# Change to the directory that this script is in.
cd "$(dirname $(readlink -f "$0"))"

intermediateCaName=$(basename "$(pwd)")

dialogBackTitle="Sign Certificate Tool - $intermediateCaName"

source settings.conf

filePath=$1

#rootCaName=$(basename "$rootCaPath")
serverCaName=$(basename "$serverIntermediateCaPath")
clientCaName=$(basename "$clientIntermediateCaPath")

function getHeaderLine() {
    local headerName=$1
    openssl asn1parse -in "$filePath" | awk '/OBJECT/ && /:'"$headerName"'/ {print NR};' | head -n 1
}

function getAsnValueByHeaderLine() {
    local headerLineNumber=$1
    openssl asn1parse -in "$filePath" | head -n $(echo "$headerLineNumber" + 1 | bc) | tail -1 | cut -d : -f 4
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

emailAddressDomain=$(echo $emailAddressValue | cut -d '@' -f 2)
emailAddressUserName=$(echo $emailAddressValue | cut -d '@' -f 1)

if [ "$emailAddressDomain" != "$emailDomain" ]; then
    set +e
    exec 3>&1
    exec 4>&1
    reply=$(dialog --colors --keep-tite --backtitle "$dialogBackTitle" --title "Email Address Issue" --nocancel --menu \
        "The e-mail address \"$emailAddressValue\" does not belong to a $emailDomain user." 0 0 0 \
        abort    "Abort" \
        continue "Continue" 2>&1 1>&3)
    returnCode=$?
    exec 3>&-
    exec 4>&-
    set -e

    if [ "$reply" != "continue" ]; then
        exit 1
    fi
fi

if [ "$commonNameValue" != "$emailAddressUserName" ]; then
    set +e
    exec 3>&1
    exec 4>&1
    reply=$(dialog --colors --keep-tite --backtitle "$dialogBackTitle" --title "Common Name Issue" --nocancel --menu \
        "The common name \"$commonNameValue\" does not match the user name in the e-mail address \"$emailAddressValue\"." 0 0 0 \
        abort    "Abort" \
        continue "Continue" 2>&1 1>&3)
    returnCode=$?
    exec 3>&-
    exec 4>&-
    set -e

    if [ "$reply" != "continue" ]; then
        exit 1
    fi
fi

indexResults=$(mktemp)
grep -e "/CN=${commonNameValue}/" -e "/CN=${commonNameValue}\$" index.txt | awk -F "\t" '{ printf $1 "\t" $2 "\t" $4 "\t" $6 "\n" }' | sed 's/\/C=.*\/O=[^/]*//' > "$indexResults"

if [ -s "$indexResults" ]; then
    sed -i '1iStatus\tCert. Expires  \tSerial\tSubject' "$indexResults"
    set +e
    exec 3>&1
    exec 4>&1
    dialog --colors --keep-tite --backtitle "$dialogBackTitle" --title "Review User's Prior Certificates" --exit-label "Done" --tailbox "$indexResults" "$(echo $(tput lines) - 5 | bc)" "$(echo $(tput cols) - 6 | bc)" 2>&1 1>&3
    returnCode=$?
    exec 3>&-
    exec 4>&-
    set -e
    rm "$indexResults"
else
    rm "$indexResults"
fi


set +e
exec 3>&1
exec 4>&1
reply=$(dialog --colors --keep-tite --backtitle "$dialogBackTitle" --title "Confirm Certificate Signature Request" --yesno \
"Do you want to sign the certificate request for user \"$commonNameValue\" and mail the resulting certificate to \"$emailAddressValue\"?" 0 0 2>&1 1>&3)
returnCode=$?
exec 3>&-
exec 4>&-
set -e

if [ $returnCode -ne 0 ]; then
    exit 1
fi

tempPath=$(mktemp -d /dev/shm/tmp.XXXXXXXXXX)
certPath=${tempPath}/postgresql.crt
trustCertPath=${tempPath}/root.crt
certRevokedListPath=${tempPath}/root.crl

#echo "Test" > "$certPath"
openssl ca -config openssl.cnf -extensions usr_cert -days "$certLifetimeDays" -notext -md $messageDigest -in "$filePath" -out "$certPath"
chmod 644 "$certPath"
openssl verify -CAfile "certs/${clientCaName}-chain.cert.pem" "$certPath"
#openssl verify -CAfile "certs/${serverCaName}-chain.cert.pem" "$certPath"

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

sed "s/USER_NAME_PLACEHOLDER/$commonNameValue/" << 'EOF' | sed "/${disableCrlRemove}root.crl/d" | mail -s "Client Certificate for PostgreSQL user $commonNameValue" -r "$(grep "^${SUDO_USER-$USER}:" /etc/passwd | cut -d : -f 5) <${SUDO_USER-$USER}@$emailDomain>" -a postgresql.zip "$emailAddressValue"
Your certificate request has been signed.  The attached certificate is good for all PostgreSQL servers that are configured to use certificates and has an account named "USER_NAME_PLACEHOLDER".

Follow the instructions for your operating system:


Windows:

1) Save the attached .zip file.

2) Browse to your %appdata% folder.

3) Browse to the postgresql folder.  If it does not exist, make sure that you followed the certificate request instructions correctly.

4) Extract the contents of the .zip file into the postgresql folder.

5) Ensure that the key file (not the certificate request file) that you generated your certificate request with is in this folder and is named postgresql.key.

6) You should now have have the following files in this folder:

* postgresql.crt
* postgresql.key
* root.crl
* root.crt


Mac / Linux:

cd ~/.postgresql
unzip ~/postgresql.zip
chmod 600 postgresql.key
EOF

cd /tmp
rm -Rf "$tempPath"

echo "The certificate (and supporting files) was e-mailed to $emailAddressValue."
