#!/usr/bin/env bash

source $(dirname $0)/scripts/common_vars.bash

# Maintain compatibility with the old jobtypes
if [[ ! $TOCI_JOBTYPE =~ "featureset" ]]; then
    echo "WARNING: USING OLD DEPLOYMENT METHOD. THE OLD DEPLOYMENT METHOD THAT USES tripleo.sh WILL BE DEPRECATED IN THE QUEENS CYCLE"
    echo "TO USE THE NEW DEPLOYMENT METHOD WITH QUICKSTART, SETUP A FEATURESET FILE AND ADD featuresetXXX TO THE JOB TYPE"
    exec $TRIPLEO_ROOT/tripleo-ci/toci_gate_test-orig.sh
fi

set -eux
export PS4='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'

# this sets
# NODEPOOL_PROVIDER (e.g tripleo-test-cloud-rh1)
# NODEPOOL_CLOUD (e.g.tripleo-test-cloud-rh1)
# NODEPOOL_REGION (e.g. regionOne)
# NODEPOOL_AZ
source /etc/nodepool/provider

# source variables common across all the scripts.

# set up distribution mirrors in openstack
NODEPOOL_MIRROR_HOST=${NODEPOOL_MIRROR_HOST:-mirror.$NODEPOOL_REGION.$NODEPOOL_CLOUD.openstack.org}
NODEPOOL_MIRROR_HOST=$(echo $NODEPOOL_MIRROR_HOST|tr '[:upper:]' '[:lower:]')
export CENTOS_MIRROR=http://$NODEPOOL_MIRROR_HOST/centos
export EPEL_MIRROR=http://$NODEPOOL_MIRROR_HOST/epel

# host setup
if [ $NODEPOOL_CLOUD == 'tripleo-test-cloud-rh1' ]; then
    source $(dirname $0)/scripts/rh2.env

    # In order to save space remove the cached git repositories, at this point in
    # CI the ones we are interested in have been cloned to /opt/stack/new. We
    # can also remove some distro images cached on the images.
    sudo rm -rf /opt/git /opt/stack/cache/files/mysql.qcow2 /opt/stack/cache/files/ubuntu-12.04-x86_64.tar.gz
fi

# Clean any cached yum metadata, it maybe stale
sudo rm /etc/yum.repos.d/epel*
sudo yum clean all

# Install additional packages
rpm -q qemu-img || \
    sudo yum install -y \
        qemu-img # used by multinode to create empty image

# NOTE(pabelanger): Current hack to make centos-7 dib work.
# TODO(pabelanger): Why is python-requests installed from pip?
sudo rm -rf /usr/lib/python2.7/site-packages/requests

# JOB_NAME used to be available from jenkins, we need to create it ourselves until
# we remove our reliance on it.
# FIXME: JOB_NAME IS USED IN CACHE UPLOAD AND PROMOTION,
# IF WE CHANGE THE JOB NAME, WE MUST UPDATE upload.cgi in mirror server
if [[ -z "${JOB_NAME-}" ]]; then
    JOB_NAME=${WORKSPACE%/}
    export JOB_NAME=${JOB_NAME##*/}
fi

# Sets whether or not this job will upload images.
export CACHEUPLOAD=0
# Stores OVB undercloud instance id
export UCINSTANCEID="null"
# Define file with set of features to test
export FEATURESET_FILE=""
export FEATURESET_CONF=""
# Define file with nodes topology
export NODES_FILE=""
# Indentifies which playbook to run
export PLAYBOOK=""
# Set the number of overcloud nodes
export NODECOUNT=0
# Sets the undercloud hostname
export UNDERCLOUD=""
# Select the tags to run
export TAGS=all
# Identify in which environment we're deploying
export ENVIRONMENT=""
# Set the overcloud controller hosts for multinode
export CONTROLLER_HOSTS=
export SUBNODES_SSH_KEY=
OVERCLOUD_DEPLOY_TIMEOUT=$((DEVSTACK_GATE_TIMEOUT-90))
TIMEOUT_SECS=$((DEVSTACK_GATE_TIMEOUT*60))
export EXTRA_VARS="--extra-vars deploy_timeout=$OVERCLOUD_DEPLOY_TIMEOUT"
export NODES_ARGS=""
export COLLECT_CONF="$TRIPLEO_ROOT/tripleo-ci/toci-quickstart/config/collect-logs.yml"


# Assemble quickstart configuration based on job type keywords
for JOB_TYPE_PART in $(sed 's/-/ /g' <<< "${TOCI_JOBTYPE:-}") ; do
    case $JOB_TYPE_PART in
        featureset*)
            FEATURESET_FILE="config/general_config/$JOB_TYPE_PART.yml"
            FEATURESET_CONF="$FEATURESET_CONF --config $FEATURESET_FILE"
        ;;
        ovb)
            OVB=1
            ENVIRONMENT="ovb"
            UCINSTANCEID=$(http_proxy= curl http://169.254.169.254/openstack/2015-10-15/meta_data.json | python -c 'import json, sys; print json.load(sys.stdin)["uuid"]') 
            PLAYBOOK="ovb.yml"
            EXTRA_VARS="$EXTRA_VARS --extra-vars @$TRIPLEO_ROOT/tripleo-ci/toci-quickstart/config/testenv/ovb.yml"
            UNDERCLOUD="undercloud"
        ;;
        multinode)
            SUBNODES_SSH_KEY=/etc/nodepool/id_rsa
            ENVIRONMENT="osinfra"
            PLAYBOOK="multinode.yml"
            FEATURESET_CONF="
                --extra-vars @config/general_config/featureset-multinode-common.yml
                $FEATURESET_CONF
            "
            EXTRA_VARS="$EXTRA_VARS --extra-vars @$TRIPLEO_ROOT/tripleo-ci/toci-quickstart/config/testenv/multinode.yml"
            UNDERCLOUD="127.0.0.2"
            TAGS="build,undercloud-setup,undercloud-scripts,undercloud-install,undercloud-post-install,overcloud-scripts,overcloud-deploy,overcloud-validate"
            CONTROLLER_HOSTS=$(sed -n 1,1p /etc/nodepool/sub_nodes)
        ;;
        singlenode)
            ENVIRONMENT="osinfra"
            UNDERCLOUD="127.0.0.2"
            PLAYBOOK="multinode.yml"
            FEATURESET_CONF="
                --extra-vars @config/general_config/featureset-multinode-common.yml
                $FEATURESET_CONF
            "
            EXTRA_VARS="$EXTRA_VARS --extra-vars @$TRIPLEO_ROOT/tripleo-ci/toci-quickstart/config/testenv/multinode.yml"
            TAGS="build,undercloud-setup,undercloud-scripts,undercloud-install,undercloud-validate"
        ;;
        periodic)
            ALLOW_PROMOTE=1
        ;;
        gate)
        ;;
        *)
        # the rest should be node configuration
            NODES_FILE="config/nodes/$JOB_TYPE_PART.yml"
        ;;
    esac
done

sudo pip install shyaml
if [[ ! -z $NODES_FILE ]]; then
    pushd $TRIPLEO_ROOT/tripleo-quickstart
    NODECOUNT=$(shyaml get-value node_count < $NODES_FILE)
    popd
    NODES_ARGS="--extra-vars @$NODES_FILE"
fi


pushd $TRIPLEO_ROOT/tripleo-ci
if [ -z "${TE_DATAFILE:-}" -a "$ENVIRONMENT" = "ovb" ] ; then

    export GEARDSERVER=${TEBROKERIP-192.168.1.1}
    # NOTE(pabelanger): We need gear for testenv, but this really should be
    # handled by tox.
    sudo pip install gear
    # Kill the whole job if it doesn't get a testenv in 20 minutes as it likely will timout in zuul
    ( sleep 1200 ; [ ! -e /tmp/toci.started ] && sudo kill -9 $$ ) &

    # We only support multi-nic at the moment
    NETISO_ENV="multi-nic"

    # provision env in rh cloud, then start quickstart
    ./testenv-client -b $GEARDSERVER:4730 -t $TIMEOUT_SECS \
        --envsize $NODECOUNT --ucinstance $UCINSTANCEID \
        --net-iso $NETISO_ENV -- ./toci_quickstart.sh
else
    # multinode preparation
    # Clear out any puppet modules on the node placed their by infra configuration
    sudo rm -rf /etc/puppet/modules/*

    # Copy nodepool keys to jenkins user
    sudo cp /etc/nodepool/id_rsa* $HOME/.ssh/
    sudo chown $USER:$USER $HOME/.ssh/id_rsa*
    chmod 0600 $HOME/.ssh/id_rsa*
    # pre-ansible requirement
    sudo mkdir -p /root/.ssh/
    cat $HOME/.ssh/id_rsa.pub >> ${HOME}/.ssh/authorized_keys
    sudo cp ${HOME}/.ssh/authorized_keys /root/.ssh/
    sudo chmod 0600 /root/.ssh/authorized_keys
    sudo chown root:root /root/.ssh/authorized_keys
    # everything below here *MUST* be translated to a role ASAP
    # empty image to fool overcloud deployment
    # set no_proxy variable
    export IP_DEVICE=${IP_DEVICE:-"eth0"}
    MY_IP=$(ip addr show dev $IP_DEVICE | awk '/inet / {gsub("/.*", "") ; print $2}')
    MY_IP_eth1=$(ip addr show dev eth1 | awk '/inet / {gsub("/.*", "") ; print $2}') || MY_IP_eth1=""

    export http_proxy=""
    undercloud_net_range="192.168.24."
    undercloud_services_ip=$undercloud_net_range"1"
    undercloud_haproxy_public_ip=$undercloud_net_range"2"
    undercloud_haproxy_admin_ip=$undercloud_net_range"3"
    export no_proxy=$undercloud_services_ip,$undercloud_haproxy_public_ip,$undercloud_haproxy_admin_ip,$MY_IP,$MY_IP_eth1

    qemu-img create -f qcow2 /home/jenkins/overcloud-full.qcow2 1G

    # multinode bootstrap script
    export BOOTSTRAP_SUBNODES_MINIMAL=0
    if [[ -z $STABLE_RELEASE || "$STABLE_RELEASE" = "ocata"  ]]; then
        BOOTSTRAP_SUBNODES_MINIMAL=1
    fi
    source $TRIPLEO_ROOT/tripleo-ci/scripts/common_functions.sh
    echo_vars_to_deploy_env_oooq
    subnodes_scp_deploy_env
    $TRIPLEO_ROOT/tripleo-ci/scripts/tripleo.sh \
        --bootstrap-subnodes \
        2>&1 | sudo dd of=/var/log/bootstrap-subnodes.log \
        || (tail -n 50 /var/log/bootstrap-subnodes.log && false)

    # create logs dir (check if collect-logs doesn't already do this)
    mkdir -p $WORKSPACE/logs

    # finally, run quickstart
    ./toci_quickstart.sh
fi

echo "Run completed"
