#!/usr/bin/env bash
set -eux

# Clean any cached yum metadata, it maybe stale
sudo yum clean all

# cd to toci directory so relative paths work (below and in toci_devtest.sh)
cd $(dirname $0)

# Mirrors
# This Fedora Mirror is in the same data center as our CI rack
export FEDORA_MIRROR=http://dl.fedoraproject.org/pub/fedora/linux
# This Mirror has resonable latency and throughput to our rack
export CENTOS_MIRROR=http://mirror.hmc.edu/centos
# This EPEL Mirror is in the same data center as our CI rack
export EPEL_MIRROR=http://dl.fedoraproject.org/pub/epel

export http_proxy=http://192.168.1.100:3128/
export GEARDSERVER=192.168.1.1
export PYPIMIRROR=192.168.1.101

export NODECOUNT=2
export OVERCLOUD_DEPLOY_ARGS=
# Switch defaults based on the job name
for JOB_TYPE_PART in $(sed 's/-/ /g' <<< "${TOCI_JOBTYPE:-}") ; do
    case $JOB_TYPE_PART in
        overcloud)
            ;;
        ceph)
            NODECOUNT=4
            OVERCLOUD_DEPLOY_ARGS="--ceph-storage-scale 2 -e /usr/share/openstack-tripleo-heat-templates/environments/puppet-ceph-devel.yaml"
            ;;
        ha)
            NODECOUNT=4
            # In ci our overcloud nodes don't have access to an external netwrok
            # --ntp-server is here to make the deploy command happy, the ci env
            # is on virt so the clocks should be in sync without it.
            OVERCLOUD_DEPLOY_ARGS="--control-scale 3 --ntp-server 0.centos.pool.ntp.org -e /usr/share/openstack-tripleo-heat-templates/environments/puppet-pacemaker.yaml"
            ;;
        containers)
            TRIPLEO_SH_ARGS="--use-containers"
            ;;
    esac
done

# print the final values of control variables to console
env | grep -E "(TOCI_JOBTYPE)="

# Set the fedora mirror, this is more reliable then relying on the repolist returned by metalink
sudo sed -i -e "s|^#baseurl=http://download.fedoraproject.org/pub/fedora/linux|baseurl=$FEDORA_MIRROR|;/^metalink/d" /etc/yum.repos.d/fedora*.repo

# Allow the instack node to have traffic forwards through here
sudo iptables -A FORWARD -i eth0 -o eth1 -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
sudo iptables -A FORWARD -i eth1 -o eth0 -j ACCEPT
echo 1 | sudo dd of=/proc/sys/net/ipv4/ip_forward

TIMEOUT_SECS=$((DEVSTACK_GATE_TIMEOUT*60))
# ./testenv-client kill everything in its own process group it it hits a timeout
# run it in a separate group to avoid getting killed along with it
set -m
./testenv-client -b $GEARDSERVER:4730 -t $TIMEOUT_SECS -- ./toci_instack.sh
