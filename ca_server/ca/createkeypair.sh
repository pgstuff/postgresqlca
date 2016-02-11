#! /bin/bash

set -e
set -u

# Change to the directory that this script is in.
cd "$(dirname $(readlink -f "$0"))"

intermediateCaName=$(basename "$(pwd)")

dialogBackTitle="Create Key & Certificate Tool - $intermediateCaName"

source settings.conf

commonNameValue=$1

#rootCaName=$(basename "$rootCaPath")
serverCaName=$(basename "$serverIntermediateCaPath")
clientCaName=$(basename "$clientIntermediateCaPath")

if [ "$#" -gt 1 ]; then
    if [ "$intermediateCaName" != "$clientCaName" ]; then
        echo "Only specify an e-mail address for generating client certificates." 1>&2
        exit 2
    fi
else
    if [ "$intermediateCaName" != "$serverCaName" ]; then
        echo "Specify an e-mail address for generating client certificates." 1>&2
        exit 2
    fi
fi

if [ "$#" -gt 1 ]; then
    emailAddressValue="$2"

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
else
    emailAddressValue=""
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

tempPath=$(mktemp -d /dev/shm/tmp.XXXXXXXXXX)

if [ -n "$emailAddressValue" ]; then
    confExtension=usr_cert
    keyPath=${tempPath}/postgresql.key
    certPath=${tempPath}/postgresql.crt
    trustCertPath=${tempPath}/root.crt
    certRevokedListPath=${tempPath}/root.crl
else
    confExtension=server_cert
    keyPath=${tempPath}/${commonNameValue}-postgresql.key
    certPath=${tempPath}/${commonNameValue}-postgresql.crt
    trustCertPath=${tempPath}/${clientCaName}-chain.cert.pem
    #trustCertPath=${tempPath}/${rootCaName}.cert.pem
    certRevokedListPath=${tempPath}/${clientCaName}.crl.pem
fi
signReq=${tempPath}/csr.csr

openssl genrsa -out "$keyPath" "$clientServerKeyLen"
chmod 600 "$keyPath"

openssl req -config openssl.cnf -key "$keyPath" -new -out "$signReq" -subj "$(./getsubject.sh ${commonNameValue} $emailAddressValue)"

openssl ca -config openssl.cnf -extensions "$confExtension" -days "$certLifetimeDays" -notext -md $messageDigest -in "$signReq" -out "$certPath"
chmod 644 "$certPath"
rm "$signReq"

openssl verify -CAfile "certs/${intermediateCaName}-chain.cert.pem" "$certPath"

if [ -n "$emailAddressValue" ]; then
    cp "certs/${serverCaName}-chain.cert.pem" "$trustCertPath"
    #cp "certs/${rootCaName}.cert.pem" "$trustCertPath"
    cp "crl/${serverCaName}.crl.pem" "$certRevokedListPath"
else
    cp "certs/${clientCaName}-chain.cert.pem" "$trustCertPath"
    #cp "certs/${rootCaName}.cert.pem" "$trustCertPath"
    cp "crl/${clientCaName}.crl.pem" "$certRevokedListPath"
fi

disableCrlRemove="x"
if [ "$disableCrl" -ne 0 ]; then
    rm "$certRevokedListPath"
    disableCrlRemove=""
fi

cd "$tempPath"

echo
echo "Enter the password for the archive that will contain the key pair."
echo
echo "Here are some suggestions:"
echo "  Random:           $(mkpasswd)"
echo "  \"Human friendly\": $(pwgen 10 1)"
echo

if [ -z "$emailAddressValue" ]; then

    # From:  http://www.postgresql.org/docs/current/static/ssl-tcp.html

    # The server certificate might be signed by an "intermediate" certificate authority, rather than one that is directly trusted by
    # clients.  To use such a certificate, append the certificate of the signing authority to the ssl_cert_file file, then its
    # parent authority's certificate, and so on up to a certificate authority, "root" or "intermediate", that is trusted by clients,
    # i.e. signed by a certificate in the clients' root.crt files.

    # To require the client to supply a trusted certificate, place certificates of the certificate authorities (CAs) that you trust
    # in the ssl_ca_file file, and set the clientcert parameter to 1 on the appropriate hostssl line(s) in pg_hba.conf.  If
    # intermediate CAs appear in ssl_ca_file, the file must also contain certificate chains to their root CAs.  Certificate
    # Revocation List (CRL) entries are also checked if the parameter ssl_crl_file is set.

    # Note that the server's ssl_ca_file lists the top-level CAs that are considered trusted for signing client certificates.  In
    # principle it need not list the CA that signed the server's certificate, though in most cases that CA would also be trusted for
    # client certificates.

    tar -cjf "${commonNameValue}-keypair.tar.bz2" *
    openssl aes-256-cbc -salt -in "${commonNameValue}-keypair.tar.bz2" -out "/tmp/${commonNameValue}-keypair.tar.bz2.aes"

    chmod o+rw "/tmp/${commonNameValue}-keypair.tar.bz2.aes"

    rm -Rf \"$tempPath\"

    cat <<EOF

To install, run (change service postgresql and \$PGDATA as necessary):
cd "\$(mktemp -d /dev/shm/tmp.XXXXXXXXXX)"
openssl aes-256-cbc -d -salt -in "/tmp/${commonNameValue}-keypair.tar.bz2.aes" -out "${commonNameValue}-keypair.tar.bz2"
tar -xjf "${commonNameValue}-keypair.tar.bz2"
rm "${commonNameValue}-keypair.tar.bz2"
sudo add_key_to_postgres.sh $(pwd) \$PGDATA ${clientCaName}
sudo service postgresql restart
rm -f "$(basename "$keyPath")" "$(basename "$certPath")" "$(basename "$trustCertPath")" "$(basename "$certRevokedListPath")"
rmdir \$(pwd); cd ~
EOF
    exit
fi

# From:  http://www.postgresql.org/docs/current/static/libpq-ssl.html

# If the server requests a trusted client certificate, libpq will send the certificate stored in file ~/.postgresql/postgresql.crt
# in the user's home directory.  The certificate must be signed by one of the certificate authorities (CA) trusted by the server.  A
# matching private key file ~/.postgresql/postgresql.key must also be present.  The private key file must not allow any access to
# world or group; achieve this by the command chmod 0600 ~/.postgresql/postgresql.key.

# In some cases, the client certificate might be signed by an "intermediate" certificate authority, rather than one that is directly
# trusted by the server.  To use such a certificate, append the certificate of the signing authority to the postgresql.crt file,
# then its parent authority's certificate, and so on up to a certificate authority, "root" or "intermediate", that is trusted by the
# server, i.e. signed by a certificate in the server's root.crt file.

# Note that the client's ~/.postgresql/root.crt lists the top-level CAs that are considered trusted for signing server certificates.
# In principle it need not list the CA that signed the client's certificate, though in most cases that CA would also be trusted for
# server certificates.

# To allow server certificate verification, the certificate(s) of one or more trusted CAs must be placed in the file
# ~/.postgresql/root.crt in the user's home directory. If intermediate CAs appear in root.crt, the file must also contain
# certificate chains to their root CAs.

# Certificate Revocation List (CRL) entries are also checked if the file ~/.postgresql/root.crl exists.

mkdir postgresql
mv *.* postgresql
7za a postgresql.zip -tzip -mem=AES256 -p postgresql

sed "s/USER_NAME_PLACEHOLDER/$commonNameValue/" << 'EOF' | sed "/${disableCrlRemove}root.crl/d" | mail -s "Client Key & Certificate for PostgreSQL user $commonNameValue" -r "$(grep "^${SUDO_USER-$USER}:" /etc/passwd | cut -d : -f 5) <${SUDO_USER-$USER}@$emailDomain>" -a postgresql.zip "$emailAddressValue"
Your key & certificate is attached to this e-mail.  It is encrypted with a password.  It is good for all PostgreSQL servers that are configured to use certificates and has an account named "USER_NAME_PLACEHOLDER".

Follow the instructions for your operating system:


Windows:

1) Save the attached .zip file.

2) Browse to your %appdata% folder.

3) Extract the contents of the .zip file into this folder.  Provide the password when requested.

4) You should now have have the folder called postgresql and it should contain the following files in it:

* postgresql.crt
* postgresql.key
* root.crl
* root.crt

5) Delete the .zip file and this e-mail.


Linux:

1) Save the attached .zip file to your home directory.

2) Run:

mkdir ~/.postgresql
cd ~/.postgresql
7za e ~/postgresql.zip

3) Enter the archive password.

4) Run:

rmdir postgresql
rm ~/postgresql.zip
chmod 600 postgresql.key

Note: The p7zip package is required to decrypt the .zip file.

5) Delete this e-mail.

EOF
#openssl verify -CAfile root.crt -purpose sslclient postgresql.crt

cd /tmp
rm -Rf "$tempPath"

echo
echo "The key, certificate, supporting files, and installation instructions was e-mailed to $emailAddressValue."
echo "Make sure that they can decrypt AES-256 encrypted .zip files."
echo "Send the password to the recipient, but do not use e-mail to do it."
