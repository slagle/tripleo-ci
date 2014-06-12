#!/usr/bin/env bash

set -eu

# cd to toci directory so relative paths work (below and in toci_devtest.sh)
cd $(dirname $0)

# Download a custom Fedora image here. We want to use an explit URL
# so that Squid caches this. I'm doing it here to test things for now...
# Once it works this code actually belongs in prepare_node_tripleo.sh
# in openstack-infra/config so the Slave node will essentially pre-cache
# it for us.
DISTRIB_CODENAME=$(lsb_release -si)
if [ $DISTRIB_CODENAME == 'Fedora' ]; then
    FEDORA_IMAGE=$(wget -q http://dl.fedoraproject.org/pub/fedora/linux/updates/20/Images/x86_64/ -O - | grep -o -E 'href="([^"#]+qcow2)"' | cut -d'"' -f2)
    wget --progress=dot:mega http://dl.fedoraproject.org/pub/fedora/linux/updates/20/Images/x86_64/$FEDORA_IMAGE
    export DIB_LOCAL_IMAGE=$PWD/$FEDORA_IMAGE
fi

# XXX: 127.0.0.1 naturally won't work for real CI but for manual
# testing running a server on the same machine is convenient.
GEARDSERVER=${GEARDSERVER:-127.0.0.1}

TIMEOUT_SECS=$((DEVSTACK_GATE_TIMEOUT*60))
./testenv-client -b $GEARDSERVER:4730 -t $TIMEOUT_SECS -- ./toci_devtest.sh
