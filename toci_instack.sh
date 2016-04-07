#!/usr/bin/env bash
set -eux

## Signal to toci_gate_test.sh we've started
touch /tmp/toci.started

if [ ! -e "$TE_DATAFILE" ] ; then
    echo "Couldn't find data file"
    exit 1
fi

export TRIPLEO_ROOT=/opt/stack/new
export PATH=/sbin:/usr/sbin:$PATH

source $TRIPLEO_ROOT/tripleo-ci/scripts/common_functions.sh

mkdir -p $WORKSPACE/logs

MY_IP=$(ip addr show dev eth1 | awk '/inet / {gsub("/.*", "") ; print $2}')

export no_proxy=192.0.2.1,$MY_IP,$MIRRORSERVER

# Periodic stable jobs set OVERRIDE_ZUUL_BRANCH, gate stable jobs
# just have the branch they're proposed to, e.g ZUUL_BRANCH, in both
# cases we need to set STABLE_RELEASE to match for tripleo.sh
export STABLE_RELEASE=
if [[ $ZUUL_BRANCH =~ ^stable/ ]]; then
    export STABLE_RELEASE=${ZUUL_BRANCH#stable/}
fi

if [[ $OVERRIDE_ZUUL_BRANCH =~ ^stable/ ]]; then
    export STABLE_RELEASE=${OVERRIDE_ZUUL_BRANCH#stable/}
fi

# Setup delorean
$TRIPLEO_ROOT/tripleo-ci/scripts/tripleo.sh --delorean-setup

# If we have no ZUUL_CHANGES then this is a periodic job, we wont be
# building a ci repo, create a dummy one.
if [ -z "${ZUUL_CHANGES:-}" ] ; then
    ZUUL_CHANGES=${ZUUL_CHANGES:-}
    mkdir -p $TRIPLEO_ROOT/delorean/data/repos/current
    touch $TRIPLEO_ROOT/delorean/data/repos/current/delorean-ci.repo
fi
ZUUL_CHANGES=${ZUUL_CHANGES//^/ }

# post ci chores to run at the end of ci
SSH_OPTIONS='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=Verbose -o PasswordAuthentication=no -o ConnectionAttempts=32'
TARCMD="sudo XZ_OPT=-3 tar -cJf - --exclude=udev/hwdb.bin --exclude=etc/services --exclude=selinux/targeted --exclude=etc/services --exclude=etc/pki /var/log /etc"
function postci(){
    set +e
    if [ -e $TRIPLEO_ROOT/delorean/data/repos/ ] ; then
        # I'd like to tar up repos/current but tar'ed its about 8M it may be a
        # bit much for the log server, maybe when we are building less
        find $TRIPLEO_ROOT/delorean/data/repos -name "*.log" | XZ_OPT=-3 xargs tar -cJf $WORKSPACE/logs/delorean_repos.tar.xz
    fi
    if [ "${SEED_IP:-}" != "" ] ; then
        # Generate extra state information from the running undercloud
        ssh root@${SEED_IP} /opt/stack/new/tripleo-ci/scripts/get_host_info.sh

        # Get logs from the undercloud
        ssh root@${SEED_IP} $TARCMD > $WORKSPACE/logs/undercloud.tar.xz

        # when we ran get_host_info.sh on the undercloud it left the output of nova list in /tmp for us
        for INSTANCE in $(ssh root@${SEED_IP} cat /tmp/nova-list.txt | grep ACTIVE | awk '{printf"%s=%s\n", $4, $12}') ; do
            IP=${INSTANCE//*=}
            NAME=${INSTANCE//=*}
            ssh $SSH_OPTIONS root@${SEED_IP} su stack -c \"scp $SSH_OPTIONS $TRIPLEO_ROOT/tripleo-ci/scripts/get_host_info.sh heat-admin@$IP:/tmp\"
            ssh $SSH_OPTIONS root@${SEED_IP} su stack -c \"ssh $SSH_OPTIONS heat-admin@$IP sudo /tmp/get_host_info.sh\"
            ssh $SSH_OPTIONS root@${SEED_IP} su stack -c \"ssh $SSH_OPTIONS heat-admin@$IP $TARCMD\" > $WORKSPACE/logs/${NAME}.tar.xz
        done
        destroy_vms &> $WORKSPACE/logs/destroy_vms.log
    fi
    return 0
}
trap "postci" EXIT

CANUSE_INSTACK_QCOW2=1
DELOREAN_BUILD_REFS=
for PROJFULLREF in $ZUUL_CHANGES ; do
    PROJ=$(filterref $PROJFULLREF)
    [ "$PROJ" == "instack-undercloud" ] && CANUSE_INSTACK_QCOW2=0
    [ "$PROJ" == "diskimage-builder" ] && CANUSE_INSTACK_QCOW2=0
    # If ci is being run for a change to ci its ok not to have a ci produced repository
    # We also don't build packages for puppet repositories, we use them from source
    if [ "$PROJ" == "tripleo-ci" ] || [[ "$PROJ" =~ ^puppet-* ]] ; then
        mkdir -p $TRIPLEO_ROOT/delorean/data/repos/current
        touch $TRIPLEO_ROOT/delorean/data/repos/current/delorean-ci.repo
    else
        # Note we only add the project once for it to be built
        if ! echo $DELOREAN_BUILD_REFS | egrep "( |^)$PROJ( |$)"; then
            DELOREAN_BUILD_REFS="$DELOREAN_BUILD_REFS $PROJ"
        fi
    fi
done

# Build packages
if [ -n "$DELOREAN_BUILD_REFS" ] ; then
    $TRIPLEO_ROOT/tripleo-ci/scripts/tripleo.sh --delorean-build $DELOREAN_BUILD_REFS
fi

# kill the http server if its already running
ps -ef | grep -i python | grep SimpleHTTPServer | awk '{print $2}' | xargs kill -9 || true
cd $TRIPLEO_ROOT/delorean/data/repos
sudo iptables -I INPUT -p tcp --dport 8766 -i eth1 -j ACCEPT
python -m SimpleHTTPServer 8766 1>$WORKSPACE/logs/yum_mirror.log 2>$WORKSPACE/logs/yum_mirror_error.log &

# Install all of the repositories we need
$TRIPLEO_ROOT/tripleo-ci/scripts/tripleo.sh --repo-setup

# Find the path to the trunk repository used
TRUNKREPOUSED=$(grep -Eo "[0-9a-z]{2}/[0-9a-z]{2}/[0-9a-z]{40}_[0-9a-z]+" /etc/yum.repos.d/delorean.repo)

# Layer the ci repository on top of it
sudo wget http://$MY_IP:8766/current/delorean-ci.repo -O /etc/yum.repos.d/delorean-ci.repo
# rewrite the baseurl in delorean-ci.repo as its currently pointing a http://trunk.rdoproject.org/..
sudo sed -i -e "s%baseurl=.*%baseurl=http://$MY_IP:8766/current/%" /etc/yum.repos.d/delorean-ci.repo
sudo sed -i -e 's%priority=.*%priority=1%' /etc/yum.repos.d/delorean-ci.repo

# Remove everything installed from a delorean repository (only requred if ci nodes are being reused)
TOBEREMOVED=$(yumdb search from_repo "*delorean*" | grep -v -e from_repo -e "Loaded plugins" || true)
[ "$TOBEREMOVED" != "" ] &&  sudo yum remove -y $TOBEREMOVED
sudo yum clean all

# ===== End : Yum repository setup ====

cd $TRIPLEO_ROOT
sudo yum install -y diskimage-builder instack-undercloud os-apply-config

PRIV_SSH_KEY=$(OS_CONFIG_FILES=$TE_DATAFILE os-apply-config --key ssh-key --type raw)
SSH_USER=$(OS_CONFIG_FILES=$TE_DATAFILE os-apply-config --key ssh-user --type username)
HOST_IP=$(OS_CONFIG_FILES=$TE_DATAFILE os-apply-config --key host-ip --type netaddress)
ENV_NUM=$(OS_CONFIG_FILES=$TE_DATAFILE os-apply-config --key env-num --type int)

mkdir -p ~/.ssh
echo "$PRIV_SSH_KEY" > ~/.ssh/id_rsa
chmod 600 ~/.ssh/id_rsa
# Generate the public key from the private one
ssh-keygen -y -f ~/.ssh/id_rsa > ~/.ssh/id_rsa.pub
# Ensure there is a newline after the last key
echo >> ~/.ssh/authorized_keys
cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys

# Kill any VM's in the test env that we may have started, freeing up RAM
# for other tests running on the TE host.
function destroy_vms(){
    ssh $SSH_OPTIONS $SSH_USER@$HOST_IP virsh destroy seed_${ENV_NUM} || true
    for i in $(seq 0 14) ; do
        ssh $SSH_OPTIONS $SSH_USER@$HOST_IP virsh destroy baremetal${ENV_NUM}brbm_one${ENV_NUM}_${i} || true
    done
}

# TODO : Remove the need for this from instack-undercloud
ls /home/jenkins/.ssh/id_rsa_virt_power || ssh-keygen -f /home/jenkins/.ssh/id_rsa_virt_power -P ""

export ANSWERSFILE=/usr/share/instack-undercloud/undercloud.conf.sample
export UNDERCLOUD_VM_NAME=instack
export ELEMENTS_PATH=/usr/share/instack-undercloud
export DIB_DISTRIBUTION_MIRROR=$CENTOS_MIRROR
export DIB_EPEL_MIRROR=$EPEL_MIRROR
export DIB_CLOUD_IMAGES=http://$MIRRORSERVER/cloud.centos.org/centos/7/images

# create DIB environment variables for all the puppet modules, $TRIPLEO_ROOT
# has all of the openstack modules with the correct HEAD. Set the DIB_REPO*
# variables so they are used (and not cloned from github)
# Note DIB_INSTALLTYPE_puppet_modules is set in tripleo.sh
for PROJDIR in $TRIPLEO_ROOT/puppet-*; do
    REV=$(git --git-dir=$PROJDIR/.git rev-parse HEAD)
    X=${PROJDIR//-/_}
    PROJ=${X##*/}
    echo "export DIB_REPOREF_$PROJ=$REV" >> $TRIPLEO_ROOT/tripleo-ci/deploy.env
    echo "export DIB_REPOLOCATION_$PROJ=$PROJDIR" >> $TRIPLEO_ROOT/tripleo-ci/deploy.env
done

IFS=$'\n'
# For the others we use local mirror server
for REPO in $(cat $TRIPLEO_ROOT/tripleo-ci/scripts/mirror-server/mirrored.list | grep -v "^#"); do
    RDIR=${REPO%% *}
    echo "export DIB_REPOLOCATION_$RDIR=http://$MIRRORSERVER/repos/$RDIR" >> $TRIPLEO_ROOT/tripleo-ci/deploy.env
done
IFS=$' \t\n'

# Build and deploy our undercloud instance
destroy_vms

# Don't get a file from cache if CACHEUPLOAD=1 (periodic job)
# If this 404's it wont error just continue without a file created
if [ "$CANUSE_INSTACK_QCOW2" == 1 ] && [ "$CACHEUPLOAD" == 0 ] ; then
    wget --progress=dot:mega http://$MIRRORSERVER/builds/current-tripleo/$UNDERCLOUD_VM_NAME.qcow2 || true
    [ -f $PWD/$UNDERCLOUD_VM_NAME.qcow2 ] && update_qcow2 $PWD/$UNDERCLOUD_VM_NAME.qcow2
fi

if [ ! -e $UNDERCLOUD_VM_NAME.qcow2 ] ; then
    disk-image-create --image-size 30 -a amd64 centos7 instack-vm -o $UNDERCLOUD_VM_NAME
fi
dd if=$UNDERCLOUD_VM_NAME.qcow2 | ssh $SSH_OPTIONS root@${HOST_IP} copyseed $ENV_NUM
ssh $SSH_OPTIONS root@${HOST_IP} virsh start seed_$ENV_NUM

# Set SEED_IP here to prevent postci ssh'ing to the undercloud before its up and running
SEED_IP=$(OS_CONFIG_FILES=$TE_DATAFILE os-apply-config --key seed-ip --type netaddress --key-default '')

# The very first thing we should do is put a valid dns server in /etc/resolv.conf, without it
# all ssh connections hit a 20 second delay until a reverse dns lookup hits a timeout
echo "nameserver 8.8.8.8" > /tmp/resolv.conf
tripleo wait_for -d 5 -l 20 -- scp $SSH_OPTIONS /tmp/resolv.conf root@${SEED_IP}:/etc/resolv.conf

for VAR in CENTOS_MIRROR EPEL_MIRROR http_proxy INTROSPECT MY_IP no_proxy NODECOUNT OVERCLOUD_DEPLOY_ARGS OVERCLOUD_UPDATE_ARGS PACEMAKER SSH_OPTIONS STABLE_RELEASE TRIPLEO_ROOT TRIPLEO_SH_ARGS NETISO_V4 NETISO_V6; do
    echo "export $VAR=\"${!VAR}\"" >> $TRIPLEO_ROOT/tripleo-ci/deploy.env
done

# Copy the required CI resources to the undercloud were we use them
tar -czf - $TRIPLEO_ROOT/tripleo-ci $TRIPLEO_ROOT/puppet-*/.git /etc/yum.repos.d/delorean* | ssh $SSH_OPTIONS root@$SEED_IP tar -C / -xzf -

ssh $SSH_OPTIONS root@${SEED_IP} <<-EOF

set -eux

source /opt/stack/new/tripleo-ci/deploy.env

ip route add 0.0.0.0/0 dev eth0 via $MY_IP

# installing basic utils
yum install -y python-simplejson dstat yum-plugin-priorities

# Add a simple system utilisation logger process
dstat -tcmndrylpg --output /var/log/dstat-csv.log >/dev/null &
disown

# https://bugs.launchpad.net/tripleo/+bug/1536136
# Add some swap to the undercloud, this is only a temp solution
# to see if it improves CI fail rates, we need to come to a concensus
# on how much RAM is acceptable as a minimum and stick to it
dd if=/dev/zero of=/swapfile count=2k bs=1M
mkswap /swapfile
swapon /swapfile

# Install our test cert so SSL tests work
cp $TRIPLEO_ROOT/tripleo-ci/test-environments/overcloud-cacert.pem /etc/pki/ca-trust/source/anchors/
update-ca-trust extract

# Run the deployment as the stack user
su -l -c "bash $TRIPLEO_ROOT/tripleo-ci/scripts/deploy.sh" stack
EOF

# If we got this far and its a periodic job, declare success and upload build artifacts
if [ $CACHEUPLOAD == 1 ] ; then
    curl http://$MIRRORSERVER/cgi-bin/upload.cgi  -F "repohash=$TRUNKREPOUSED" -F "upload=@$TRIPLEO_ROOT/$UNDERCLOUD_VM_NAME.qcow2;filename=$UNDERCLOUD_VM_NAME.qcow2"
    curl http://$MIRRORSERVER/cgi-bin/upload.cgi  -F "repohash=$TRUNKREPOUSED" -F "$JOB_NAME=SUCCESS"
fi

exit 0
echo 'Run completed.'
