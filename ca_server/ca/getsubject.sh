#! /bin/bash

set -e
set -u

# Change to the directory that this script is in.
cd "$(dirname $(readlink -f "$0"))"

source settings.conf

if [ "$#" -gt 1 ]; then
    emailAddress="/emailAddress=$2"
else
    emailAddress=""
fi

echo "/C=$countryName/ST=$stateOrProvinceName/L=$localityName/O=$organizationName/CN=$1${emailAddress}"
