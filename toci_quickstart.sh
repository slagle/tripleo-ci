#!/usr/bin/env bash
set -eux
set -o pipefail
export ANSIBLE_NOCOLOR=1

LOCAL_WORKING_DIR="$WORKSPACE/.quickstart"
WORKING_DIR="$HOME"
LOGS_DIR=$WORKSPACE/logs

source $TRIPLEO_ROOT/tripleo-ci/scripts/oooq_common_functions.sh

## Signal to toci_gate_test.sh we've started by
touch /tmp/toci.started

export DEFAULT_ARGS="
    --no-clone
    --working-dir $LOCAL_WORKING_DIR
    --retain-inventory
    --teardown none
    --extra-vars tripleo_root=$TRIPLEO_ROOT
    --extra-vars working_dir=$WORKING_DIR
    --extra-vars validation_args='--validation-errors-nonfatal'
    --release tripleo-ci/$QUICKSTART_RELEASE
"

# --install-deps arguments installs deps and then quits, no other arguments are
# processed.
QUICKSTART_PREPARE_CMD="
    ./quickstart.sh
    --install-deps
"

QUICKSTART_INSTALL_CMD="
    ./quickstart.sh
    --bootstrap
    --tags $TAGS
    $DEFAULT_ARGS
    $NODES_ARGS
    $ENV_VARS
    $FEATURESET_CONF
    $EXTRA_VARS
    --playbook $PLAYBOOK
    $UNDERCLOUD
"

QUICKSTART_COLLECTLOGS_CMD="
    ./quickstart.sh
    $DEFAULT_ARGS
    --extra-vars @$COLLECT_CONF
    --tags all
    $NODES_ARGS
    $ENV_VARS
    $FEATURESET_CONF
    $EXTRA_VARS
    --playbook collect-logs.yml
    --extra-vars artcl_collect_dir=$LOGS_DIR
    $UNDERCLOUD
"
mkdir -p $LOCAL_WORKING_DIR
# TODO(gcerami) parametrize hosts
cp $TRIPLEO_ROOT/tripleo-ci/toci-quickstart/config/testenv/${ENVIRONMENT}_hosts $LOCAL_WORKING_DIR/hosts
cp $TRIPLEO_ROOT/tripleo-ci/toci-quickstart/playbooks/* $TRIPLEO_ROOT/tripleo-quickstart/playbooks/

pushd $TRIPLEO_ROOT/tripleo-quickstart/

$QUICKSTART_PREPARE_CMD
run_with_timeout $START_JOB_TIME $QUICKSTART_INSTALL_CMD \
    2>&1 | tee $LOGS_DIR/quickstart_install.log && exit_value=0 || exit_value=$?

# Print status of playbook run
[[ "$exit_value" == 0 ]] && echo "Playbook run passed successfully" || echo "Playbook run failed"
## LOGS COLLECTION

$QUICKSTART_COLLECTLOGS_CMD \
    > $LOGS_DIR/quickstart_collect_logs.log || \
    echo "WARNING: quickstart collect-logs failed, check quickstart_collectlogs.log for details"

# Temporary workaround to make postci log visible as it was before
cp $LOGS_DIR/undercloud/var/log/postci.txt.gz $LOGS_DIR/ || true

if [[ -e $LOGS_DIR/undercloud/home/$USER/tempest/testrepository.subunit.gz ]]; then
    cp $LOGS_DIR/undercloud/home/$USER/tempest/testrepository.subunit.gz ${LOGS_DIR}/testrepository.subunit.gz
elif [[ -e $LOGS_DIR/undercloud/home/$USER/pingtest.subunit.gz ]]; then
    cp $LOGS_DIR/undercloud/home/$USER/pingtest.subunit.gz ${LOGS_DIR}/testrepository.subunit.gz
elif [[ -e $LOGS_DIR/undercloud/home/$USER/undercloud_sanity.subunit.gz ]]; then
    cp $LOGS_DIR/undercloud/home/$USER/undercloud_sanity.subunit.gz ${LOGS_DIR}/testrepository.subunit.gz
fi

# Copy tempest.html to root dir
cp $LOGS_DIR/undercloud/home/$USER/tempest/tempest.html.gz ${LOGS_DIR} || true

# Copy tempest and .testrepository directory to /opt/stack/new/tempest and
# unzip
sudo mkdir -p /opt/stack/new
sudo cp -Rf $LOGS_DIR/undercloud/home/$USER/tempest /opt/stack/new || true
sudo gzip -d -r /opt/stack/new/tempest/.testrepository || true

export ARA_DATABASE="sqlite:///$LOCAL_WORKING_DIR/ara.sqlite"
$LOCAL_WORKING_DIR/bin/ara generate html $LOGS_DIR/ara_oooq || true
gzip --best --recursive $LOGS_DIR/ara_oooq || true
popd

sudo unbound-control dump_cache > /tmp/dns_cache.txt
sudo chown ${USER}: /tmp/dns_cache.txt
cat /tmp/dns_cache.txt | gzip - > $LOGS_DIR/dns_cache.txt.gz


# record the size of the logs directory
# -L, --dereference     dereference all symbolic links
# Note: tail -n +1 is to prevent the error "Broken Pipe" e.g. "sort: write failed: standard output: Broken pipe"
du -L -ch $LOGS_DIR/* | tail -n +1 | sort -rh | head -n 200 &> $LOGS_DIR/log-size.txt || true

if [[ "$PERIODIC" == 1 && -e $WORKSPACE/hash_info.sh ]] ; then
    echo export JOB_EXIT_VALUE=$exit_value >> $WORKSPACE/hash_info.sh
fi

echo 'Quickstart completed.'
exit $exit_value
