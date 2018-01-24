set -eux
set -o pipefail

cd

# This sets all the environment variables for undercloud and overcloud installation
source $TRIPLEO_ROOT/tripleo-ci/deploy.env
source $TRIPLEO_ROOT/tripleo-ci/scripts/metrics.bash
source $TRIPLEO_ROOT/tripleo-ci/scripts/common_functions.sh

# Prevent python from buffering stdout, so timestamps are set at appropriate times
export PYTHONUNBUFFERED=true

export DIB_DISTRIBUTION_MIRROR=$CENTOS_MIRROR
export STABLE_RELEASE=${STABLE_RELEASE:-""}

# the TLS everywhere job requires the undercloud to have a domain set so it can
# enroll to FreeIPA
if [ $CA_SERVER == 1 ] ; then
    # This is needed since we use scripts that are located both in t-h-t and
    # tripleo-common for setting up our test CA.
    sudo yum install -yq \
        openstack-tripleo-heat-templates \
        openstack-tripleo-common \
        ipa-client \
        python-novajoin

    export TRIPLEO_DOMAIN=tripleodomain.example.com
    export CA_SERVER_HOSTNAME=ipa.$TRIPLEO_DOMAIN
    export CA_ADMIN_PASS=$(uuidgen)
    export CA_DIR_MANAGER_PASS=$(uuidgen)
    export CA_SECRET=$(uuidgen)
    export UNDERCLOUD_FQDN=undercloud.$TRIPLEO_DOMAIN
    # We can access the CA server through this address for bootstrapping
    # purposes.
    export CA_SERVER_PRIVATE_IP=$(jq -r '.extra_nodes[0].ips.private[0].addr' ~/instackenv.json)
    # Address that will be used for the provisioning interface. The undercloud
    # and the overcloud nodes should have access to this.
    export CA_SERVER_IP="192.168.24.250"
    export CA_SERVER_CIDR="${CA_SERVER_IP}/24"

    echo "$CA_SERVER_PRIVATE_IP  $CA_SERVER_HOSTNAME" | sudo tee -a /etc/hosts

    cat <<EOF >~/freeipa-setup.env
export Hostname=$CA_SERVER_HOSTNAME
export FreeIPAIP=$CA_SERVER_IP
export AdminPassword=$CA_ADMIN_PASS
export DirectoryManagerPassword=$CA_DIR_MANAGER_PASS
export HostsSecret=$CA_SECRET
export UndercloudFQDN=$UNDERCLOUD_FQDN
export ProvisioningCIDR=$CA_SERVER_CIDR
export UsingNovajoin=1
EOF

    # Set undercloud FQDN
    sudo hostnamectl set-hostname --static $UNDERCLOUD_FQDN

    # Copy CA env file and installation script
    scp $SSH_OPTIONS ~/freeipa-setup.env centos@$CA_SERVER_PRIVATE_IP:/tmp/freeipa-setup.env
    scp $SSH_OPTIONS /usr/share/openstack-tripleo-heat-templates/ci/scripts/freeipa_setup.sh centos@$CA_SERVER_PRIVATE_IP:~/freeipa_setup.sh

    # Set up CA
    ssh $SSH_OPTIONS -tt centos@$CA_SERVER_PRIVATE_IP "sudo bash ~/freeipa_setup.sh"

    # enroll to CA
    sudo /usr/libexec/novajoin-ipa-setup \
        --principal admin \
        --password $CA_ADMIN_PASS \
        --server $CA_SERVER_HOSTNAME \
        --realm $(echo $TRIPLEO_DOMAIN | awk '{print toupper($0)}') \
        --domain $TRIPLEO_DOMAIN \
        --hostname $UNDERCLOUD_FQDN \
        --otp-file /tmp/ipa-otp.txt \
        --precreate

    cat <<EOF >$TRIPLEO_ROOT/cloud-names.yaml
parameter_defaults:
  CloudDomain: $TRIPLEO_DOMAIN
  CloudName: overcloud.$TRIPLEO_DOMAIN
  CloudNameInternal: overcloud.internalapi.$TRIPLEO_DOMAIN
  CloudNameStorage: overcloud.storage.$TRIPLEO_DOMAIN
  CloudNameStorageManagement: overcloud.storagemgmt.$TRIPLEO_DOMAIN
  CloudNameCtlplane: overcloud.ctlplane.$TRIPLEO_DOMAIN
EOF
fi

cat <<EOF >$HOME/undercloud-hieradata-override.yaml
ironic::drivers::deploy::http_port: 3816
EOF

echo '[DEFAULT]' > ~/undercloud.conf
echo "hieradata_override = $HOME/undercloud-hieradata-override.yaml" >> ~/undercloud.conf
cat <<EOF >>~/undercloud.conf
network_cidr = 192.168.24.0/24
local_ip = 192.168.24.1/24
network_gateway = 192.168.24.1
undercloud_public_vip = 192.168.24.2
undercloud_admin_vip = 192.168.24.3
masquerade_network = 192.168.24.0/24
dhcp_start = 192.168.24.5
dhcp_end = 192.168.24.30
inspection_iprange = 192.168.24.100,192.168.24.120
EOF

if [ $UNDERCLOUD_SSL == 1 ] ; then
    echo 'generate_service_certificate = True' >> ~/undercloud.conf
fi

if [ $UNDERCLOUD_TELEMETRY == 0 ] ; then
    echo 'enable_telemetry = False' >> ~/undercloud.conf
    echo 'enable_legacy_ceilometer_api = false' >> ~/undercloud.conf
fi
if [ $UNDERCLOUD_UI == 0 ] ; then
    echo 'enable_ui = False' >> ~/undercloud.conf
fi
if [ $UNDERCLOUD_VALIDATIONS == 0 ] ; then
    echo 'enable_validations = False' >> ~/undercloud.conf
fi
if [ $RUN_TEMPEST_TESTS != 1 ] ; then
    echo 'enable_tempest = False' >> ~/undercloud.conf
fi
if [ $CA_SERVER == 1 ] ; then
    echo 'enable_novajoin = True' >> ~/undercloud.conf
    echo "undercloud_hostname = $UNDERCLOUD_FQDN" >> ~/undercloud.conf
    echo "ipa_otp = $(cat /tmp/ipa-otp.txt)" >> ~/undercloud.conf
    echo "undercloud_nameservers = $CA_SERVER_IP" >> ~/undercloud.conf
    echo "overcloud_domain_name = $TRIPLEO_DOMAIN" >> ~/undercloud.conf

    echo "nova::api::vendordata_dynamic_connect_timeout: 20" >> ~/undercloud-hieradata-override.yaml
    echo "nova::api::vendordata_dynamic_read_timeout: 20" >> ~/undercloud-hieradata-override.yaml

    # NOTE(jaosorior): the DNSServers from the overcloud need to point to the
    # CA so the domain can be discovered.
    sed -i 's/\(DnsServers: \).*/\1["'$CA_SERVER_IP'", "8.8.8.8"]/' \
        $TRIPLEO_ROOT/tripleo-ci/test-environments/network-templates/network-environment.yaml
    sed -i 's/\(DnsServers: \).*/\1["'$CA_SERVER_IP'", "8.8.8.8"]/' \
        $TRIPLEO_ROOT/tripleo-ci/test-environments/net-iso.yaml

    # Use FreeIPA as nameserver
    echo -e "nameserver 192.168.24.250\nnameserver 8.8.8.8" | sudo tee /etc/resolv.conf
fi

if [ $UNDERCLOUD_HEAT_CONVERGENCE == 1 ] ; then
    cat <<EOF >>$HOME/undercloud-hieradata-override.yaml
heat::engine::convergence_engine: true
EOF
fi
# TODO: fix this in instack-undercloud
sudo mkdir -p /etc/puppet/hieradata

if [ "$OSINFRA" = 1 ]; then
    echo "net_config_override = $TRIPLEO_ROOT/tripleo-ci/undercloud-configs/net-config-multinode.json.template" >> ~/undercloud.conf

    # Use the dummy network interface if on mitaka
    if [ "$STABLE_RELEASE" = "mitaka" ]; then
        echo "local_interface = ci-dummy" >> ~/undercloud.conf
    fi
fi

# If we're testing an undercloud upgrade, remove the ci repo, since we don't
# want to consume the package being tested until we actually do the upgrade.
if [ "$UNDERCLOUD_MAJOR_UPGRADE" == 1 ] ; then
    sudo rm -f /etc/yum.repos.d/delorean-ci.repo
fi

echo "INFO: Check /var/log/undercloud_install.txt for undercloud install output"
echo "INFO: This file can be found in logs/undercloud.tar.xz in the directory containing console.log"
start_metric "tripleo.${STABLE_RELEASE:-master}.${TOCI_JOBTYPE}.undercloud.install.seconds"
$TRIPLEO_ROOT/tripleo-ci/scripts/tripleo.sh --undercloud 2>&1 | awk '{ print strftime("%Y-%m-%d %H:%M:%S.000"), "|", $0; fflush(); }' | sudo dd of=/var/log/undercloud_install.txt || (tail -n 50 /var/log/undercloud_install.txt && false)
stop_metric "tripleo.${STABLE_RELEASE:-master}.${TOCI_JOBTYPE}.undercloud.install.seconds"

# FreeIPA contains an LDAP server, so we're gonna use that to set up a keystone
# domain that reads from that ldap server.
if [ $CA_SERVER == 1 ] ; then
    export LDAP_DOMAIN_NAME=freeipadomain
    export LDAP_READER_INIT_PASS=$(uuidgen)
    export LDAP_READER_PASS=$(uuidgen)
    export DEMO_USER_INIT_PASS=$(uuidgen)
    export DEMO_USER_PASS=$(uuidgen)

    echo $CA_ADMIN_PASS | kinit admin
    echo "$LDAP_READER_INIT_PASS" | ipa user-add keystone --cn="keystone user" \
        --first="keystone" --last="user" --password
    echo "$DEMO_USER_INIT_PASS" | ipa user-add demo --cn="demo user" \
        --first="demo" --last="user" --password
    kdestroy -A

    # Reset password. Since kerberos prompts for the password to be reset on
    # first usage.
    echo -e "$LDAP_READER_INIT_PASS\n$LDAP_READER_PASS\n$LDAP_READER_PASS" | kinit keystone
    kdestroy -A
    echo -e "$DEMO_USER_INIT_PASS\n$DEMO_USER_PASS\n$DEMO_USER_PASS" | kinit demo
    kdestroy -A

    export LDAP_SUFFIX=$(echo $TRIPLEO_DOMAIN | sed -e 's/^/dc=/' -e 's/\./,dc=/g')

    # Create LDAP configuration in heat environment
    cat <<EOF >$TRIPLEO_ROOT/keystone-ldap.yaml
parameter_defaults:
  KeystoneLDAPDomainEnable: true
  KeystoneLDAPBackendConfigs:
    $LDAP_DOMAIN_NAME:
      url: ldaps://$CA_SERVER_HOSTNAME
      user: uid=keystone,cn=users,cn=accounts,$LDAP_SUFFIX
      password: $LDAP_READER_PASS
      suffix: $LDAP_SUFFIX
      user_tree_dn: cn=users,cn=accounts,$LDAP_SUFFIX
      user_objectclass: inetOrgPerson
      user_id_attribute: uid
      user_name_attribute: uid
      user_mail_attribute: mail
      user_allow_create: false
      user_allow_update: false
      user_allow_delete: false
      group_tree_dn: cn=groups,cn=accounts,$LDAP_SUFFIX
      group_objectclass: groupOfNames
      group_id_attribute: cn
      group_name_attribute: cn
      group_member_attribute: member
      group_desc_attribute: description
      group_allow_create: false
      group_allow_update: false
      group_allow_delete: false
      user_enabled_attribute: nsAccountLock
      user_enabled_default: False
      user_enabled_invert: true
EOF
fi

if [ "$OVB" = 1 ]; then

    # eth1 is on the provisioning netwrok and doesn't have dhcp, so we need to set its MTU manually.
    sudo ip link set dev eth1 up
    sudo ip link set dev eth1 mtu 1400

    echo -e "\ndhcp-option-force=26,1400" | sudo tee -a /etc/dnsmasq-ironic.conf
    sudo systemctl restart 'neutron-*'

    # The undercloud install is creating file in ~/.cache as root
    # change them back so we can build overcloud images
    sudo chown -R $USER ~/.cache || true

    # check the power status of the last IPMI device we have details for
    # this ensures the BMC is ready and sanity tests that its working
    PMADDR=$(jq '.nodes[length-1].pm_addr' < ~/instackenv.json | tr '"' ' ')
    $TRIPLEO_ROOT/tripleo-ci/scripts/wait_for -d 10 -l 40 -- ipmitool -I lanplus -H $PMADDR -U admin -P password power status
fi

if [ $INTROSPECT == 1 ] ; then
    # I'm removing most of the nodes in the env to speed up discovery
    # This could be in jq but I don't know how
    # Only do this for jobs that use introspection, as it makes the likelihood
    # of hitting https://bugs.launchpad.net/tripleo/+bug/1341420 much higher
    python -c "import simplejson ; d = simplejson.loads(open(\"instackenv.json\").read()) ; del d[\"nodes\"][$NODECOUNT:] ; print simplejson.dumps(d)" > instackenv_reduced.json
    mv instackenv_reduced.json instackenv.json

    # Lower the timeout for introspection to decrease failure time
    # It should not take more than 10 minutes with IPA ramdisk and no extra collectors
    sudo sed -i '2itimeout = 600' /etc/ironic-inspector/inspector.conf
    sudo systemctl restart openstack-ironic-inspector
fi

if [ $NETISO_V4 -eq 1 ] || [ $NETISO_V6 -eq 1 ]; then

    # Update our floating range to use a 10. /24
    export FLOATING_IP_CIDR=${FLOATING_IP_CIDR:-"10.0.0.0/24"}
    export FLOATING_IP_START=${FLOATING_IP_START:-"10.0.0.100"}
    export FLOATING_IP_END=${FLOATING_IP_END:-"10.0.0.200"}
    export EXTERNAL_NETWORK_GATEWAY=${EXTERNAL_NETWORK_GATEWAY:-"10.0.0.1"}

# Make our undercloud act as the external gateway
# OVB uses eth2 as the "external" network
# NOTE: seed uses eth0 for the local network.
    cat >> /tmp/eth2.cfg <<EOF_CAT
network_config:
    - type: interface
      name: eth2
      use_dhcp: false
      addresses:
        - ip_netmask: 10.0.0.1/24
        - ip_netmask: 2001:db8:fd00:1000::1/64
EOF_CAT
    sudo os-net-config -c /tmp/eth2.cfg -v
fi

if [ "$OSINFRA" = "0" ]; then
    # Our ci underclouds don't have enough RAM to allow us to use a tmpfs
    export DIB_NO_TMPFS=1
    # No point waiting for a grub prompt in ci
    export DIB_GRUB_TIMEOUT=0
    # Override the default repositories set by tripleo.sh, to add the delorean-ci repository
    export OVERCLOUD_IMAGES_DIB_YUM_REPO_CONF=$(ls /etc/yum.repos.d/delorean*)
    # Directing the output of this command to a file as its extreemly verbose
    echo "INFO: Check /var/log/image_build.txt for image build output"
    echo "INFO: This file can be found in logs/undercloud.tar.xz in the directory containing console.log"
    start_metric "tripleo.${STABLE_RELEASE:-master}.${TOCI_JOBTYPE}.overcloud.images.seconds"
    $TRIPLEO_ROOT/tripleo-ci/scripts/tripleo.sh --overcloud-images 2>&1 | awk '{ print strftime("%Y-%m-%d %H:%M:%S.000"), "|", $0; fflush(); }' | sudo dd of=/var/log/image_build.txt || (tail -n 50 /var/log/image_build.txt && false)
    stop_metric "tripleo.${STABLE_RELEASE:-master}.${TOCI_JOBTYPE}.overcloud.images.seconds"

    OVERCLOUD_IMAGE_MB=$(du -ms overcloud-full.qcow2 | cut -f 1)
    record_metric "tripleo.${STABLE_RELEASE:-master}.${TOCI_JOBTYPE}.overcloud.image.size_mb" "$OVERCLOUD_IMAGE_MB"

    start_metric "tripleo.${STABLE_RELEASE:-master}.${TOCI_JOBTYPE}.register.nodes.seconds"
    if [ $INTROSPECT == 1 ]; then
        export INTROSPECT_NODES=1
    fi
    $TRIPLEO_ROOT/tripleo-ci/scripts/tripleo.sh --register-nodes
    # We don't want to keep this set for further calls to tripleo.sh
    unset INTROSPECT_NODES
    stop_metric "tripleo.${STABLE_RELEASE:-master}.${TOCI_JOBTYPE}.register.nodes.seconds"

    if [ $INTROSPECT == 1 ] ; then
       start_metric "tripleo.${STABLE_RELEASE:-master}.${TOCI_JOBTYPE}.introspect.seconds"
       $TRIPLEO_ROOT/tripleo-ci/scripts/tripleo.sh --introspect-nodes
       stop_metric "tripleo.${STABLE_RELEASE:-master}.${TOCI_JOBTYPE}.introspect.seconds"
    fi

    if [ $PREDICTABLE_PLACEMENT == 1 ]; then
        source ~/stackrc
        NODE_ID_0=$(ironic node-list | grep available | head -n 1 | tail -n 1 | awk '{print $2}')
        NODE_ID_1=$(ironic node-list | grep available | head -n 2 | tail -n 1 | awk '{print $2}')
        NODE_ID_2=$(ironic node-list | grep available | head -n 3 | tail -n 1 | awk '{print $2}')
        NODE_ID_3=$(ironic node-list | grep available | head -n 4 | tail -n 1 | awk '{print $2}')
        ironic node-update $NODE_ID_0 replace properties/capabilities='node:controller-0,boot_option:local'
        ironic node-update $NODE_ID_1 replace properties/capabilities='node:controller-1,boot_option:local'
        ironic node-update $NODE_ID_2 replace properties/capabilities='node:controller-2,boot_option:local'
        ironic node-update $NODE_ID_3 replace properties/capabilities='node:compute-0,boot_option:local'
    fi

    sleep 60
fi


if [ -n "${OVERCLOUD_UPDATE_ARGS:-}" ] ; then
    # Reinstall openstack-tripleo-heat-templates from delorean-current.
    # Since we're testing updates, we want to remove any version we may have
    # installed from the delorean-ci repo and install from delorean-current,
    # or just delorean in the case of stable branches.
    sudo rpm -ev --nodeps openstack-tripleo-heat-templates
    sudo yum -y --disablerepo=* --enablerepo=delorean,delorean-current install openstack-tripleo-heat-templates
fi

if [ "$MULTINODE" = "1" ]; then
    # Start the script that will configure os-collect-config on the subnodes
    source ~/stackrc

    if [ "$OVERCLOUD_MAJOR_UPGRADE" == 1 ] ; then
        # Download the previous release openstack-tripleo-heat-templates to a directory
        # we then deploy this and later upgrade to the default --templates location
        # FIXME - we should make the tht-compat package work here instead
        OLD_THT=$(curl https://trunk.rdoproject.org/centos7-$UPGRADE_RELEASE/current/ | grep "openstack-tripleo-heat-templates" | grep "noarch.rpm" | grep -v "tripleo-heat-templates-compat" | sed "s/^.*>openstack-tripleo-heat-templates/openstack-tripleo-heat-templates/" | cut -d "<" -f1)
        echo "Downloading https://trunk.rdoproject.org/centos7-$UPGRADE_RELEASE/current/$OLD_THT"
        rm -fr $TRIPLEO_ROOT/$UPGRADE_RELEASE/*
        mkdir -p $TRIPLEO_ROOT/$UPGRADE_RELEASE
        curl -o $TRIPLEO_ROOT/$UPGRADE_RELEASE/$OLD_THT https://trunk.rdoproject.org/centos7-$UPGRADE_RELEASE/current/$OLD_THT
        pushd $TRIPLEO_ROOT/$UPGRADE_RELEASE
        rpm2cpio openstack-tripleo-heat-templates-*.rpm | cpio -ivd
        popd
        # Backup current deploy args:
        UPGRADE_OVERCLOUD_DEPLOY_ARGS=$OVERCLOUD_DEPLOY_ARGS
        # Rewrite all template paths to ensure paths match the
        # --templates location
        TEMPLATE_PATH="/usr/share/openstack-tripleo-heat-templates"
        ENV_PATH="-e $TEMPLATE_PATH"
        STABLE_TEMPLATE_PATH="$TRIPLEO_ROOT/$UPGRADE_RELEASE/usr/share/openstack-tripleo-heat-templates"
        STABLE_ENV_PATH="-e $STABLE_TEMPLATE_PATH"
        echo "SHDEBUG OVERCLOUD_DEPLOY_ARGS BEFORE=$OVERCLOUD_DEPLOY_ARGS"
        UPGRADE_OVERCLOUD_DEPLOY_ARGS=${UPGRADE_OVERCLOUD_DEPLOY_ARGS//$STABLE_ENV_PATH/$ENV_PATH}
        OVERCLOUD_DEPLOY_ARGS=${OVERCLOUD_DEPLOY_ARGS//$ENV_PATH/$STABLE_ENV_PATH}
        echo "UPGRADE_OVERCLOUD_DEPLOY_ARGS=$UPGRADE_OVERCLOUD_DEPLOY_ARGS"
        echo "OVERCLOUD_DEPLOY_ARGS=$OVERCLOUD_DEPLOY_ARGS"
        # Set deploy args for stable deployment:
        export OVERCLOUD_DEPLOY_ARGS="$OVERCLOUD_DEPLOY_ARGS --templates $STABLE_TEMPLATE_PATH -e $STABLE_TEMPLATE_PATH/environments/deployed-server-environment.yaml -e $STABLE_TEMPLATE_PATH/environments/services/sahara.yaml"
        if [ ! -z $UPGRADE_ENV ]; then
            export OVERCLOUD_DEPLOY_ARGS="$OVERCLOUD_DEPLOY_ARGS -e $TRIPLEO_ROOT/$UPGRADE_RELEASE/$UPGRADE_ENV"
        fi
        echo_vars_to_deploy_env
        $TRIPLEO_ROOT/$UPGRADE_RELEASE/usr/share/openstack-tripleo-heat-templates/deployed-server/scripts/get-occ-config.sh 2>&1 | sudo dd of=/var/log/deployed-server-os-collect-config.log &
    else
        /usr/share/openstack-tripleo-heat-templates/deployed-server/scripts/get-occ-config.sh 2>&1 | sudo dd of=/var/log/deployed-server-os-collect-config.log &
    fi
    # Create dummy overcloud-full image since there is no way (yet) to disable
    # this constraint in the heat templates
    if ! openstack image show overcloud-full; then
        qemu-img create -f qcow2 overcloud-full.qcow2 1G
        glance image-create \
            --container-format bare \
            --disk-format qcow2 \
            --name overcloud-full \
            --file overcloud-full.qcow2
    fi
fi

if [ $OVERCLOUD == 1 ] ; then
    source ~/stackrc
    start_metric "tripleo.${STABLE_RELEASE:-master}.${TOCI_JOBTYPE}.overcloud.deploy.seconds"
    http_proxy= $TRIPLEO_ROOT/tripleo-ci/scripts/tripleo.sh --overcloud-deploy ${TRIPLEO_SH_ARGS:-}
    stop_metric "tripleo.${STABLE_RELEASE:-master}.${TOCI_JOBTYPE}.overcloud.deploy.seconds"
    # Add hosts to /etc/hosts
    openstack stack output show overcloud HostsEntry -f value -c output_value | sudo tee -a /etc/hosts
fi

if [ $UNDERCLOUD_IDEMPOTENT == 1 ]; then
    echo "INFO: Check /var/log/undercloud_install_idempotent.txt for undercloud install output"
    echo "INFO: This file can be found in logs/undercloud.tar.xz in the directory containing console.log"
    $TRIPLEO_ROOT/tripleo-ci/scripts/tripleo.sh --undercloud 2>&1 | sudo dd of=/var/log/undercloud_install_idempotent.txt || (tail -n 50 /var/log/undercloud_install_idempotent.txt && false)
fi

if [ -n "${OVERCLOUD_UPDATE_ARGS:-}" ] ; then
    # Reinstall openstack-tripleo-heat-templates, this will pick up the version
    # from the delorean-ci repo if the patch being tested is from
    # tripleo-heat-templates, otherwise it will just reinstall from
    # delorean-current.
    sudo rpm -ev --nodeps openstack-tripleo-heat-templates
    sudo yum -y install openstack-tripleo-heat-templates

    start_metric "tripleo.${STABLE_RELEASE:-master}.${TOCI_JOBTYPE}.overcloud.update.seconds"
    http_proxy= $TRIPLEO_ROOT/tripleo-ci/scripts/tripleo.sh --overcloud-update ${TRIPLEO_SH_ARGS:-}
    stop_metric "tripleo.${STABLE_RELEASE:-master}.${TOCI_JOBTYPE}.overcloud.update.seconds"
fi

if [ "$MULTINODE" == 0 ] && [ "$OVERCLOUD" == 1 ] ; then
    # Sanity test we deployed what we said we would
    source ~/stackrc
    [ "$NODECOUNT" != $(nova list | grep ACTIVE | wc -l | cut -f1 -d " ") ] && echo "Wrong number of nodes deployed" && exit 1
    if [ $PREDICTABLE_PLACEMENT == 1 ]; then
        # Verify our public VIP is the one we specified
        grep -q 10.0.0.9 ~/overcloudrc || (echo "Wrong public vip deployed " && exit 1)
        # Verify our specified hostnames were used
        INSTANCE_ID_0=$(nova list | grep controller-0-tripleo-ci-a-foo | awk '{print $2}')
        INSTANCE_ID_1=$(nova list | grep controller-1-tripleo-ci-b-bar | awk '{print $2}')
        INSTANCE_ID_2=$(nova list | grep controller-2-tripleo-ci-c-baz | awk '{print $2}')
        INSTANCE_ID_3=$(nova list | grep compute-0-tripleo-ci-a-test | awk '{print $2}')
        # Verify the correct ironic nodes were used
        echo "Verifying predictable placement configuration was honored."
        ironic node-list | grep $INSTANCE_ID_0 | grep -q $NODE_ID_0 || (echo "$INSTANCE_ID_0 not deployed to node $NODE_ID_0" && exit 1)
        ironic node-list | grep $INSTANCE_ID_1 | grep -q $NODE_ID_1 || (echo "$INSTANCE_ID_1 not deployed to node $NODE_ID_1" && exit 1)
        ironic node-list | grep $INSTANCE_ID_2 | grep -q $NODE_ID_2 || (echo "$INSTANCE_ID_2 not deployed to node $NODE_ID_2" && exit 1)
        ironic node-list | grep $INSTANCE_ID_3 | grep -q $NODE_ID_3 || (echo "$INSTANCE_ID_3 not deployed to node $NODE_ID_3" && exit 1)
        echo "Verified."
    fi

    if [ $PACEMAKER == 1 ] ; then
        # Wait for the pacemaker cluster to settle and all resources to be
        # available. heat-{api,engine} are the best candidates since due to the
        # constraint ordering they are typically started last. We'll wait up to
        # 180s.
        start_metric "tripleo.${STABLE_RELEASE:-master}.${TOCI_JOBTYPE}.overcloud.settle.seconds"
        timeout -k 10 240 ssh $SSH_OPTIONS heat-admin@$(nova list | grep controller-0 | awk '{print $12}' | cut -d'=' -f2) sudo crm_resource -r openstack-heat-api --wait || {
            exitcode=$?
            echo "crm_resource for openstack-heat-api has failed!"
            exit $exitcode
            }
        timeout -k 10 240 ssh $SSH_OPTIONS heat-admin@$(nova list | grep controller-0 | awk '{print $12}' | cut -d'=' -f2) sudo crm_resource -r openstack-heat-engine --wait|| {
            exitcode=$?
            echo "crm_resource for openstack-heat-engine has failed!"
            exit $exitcode
            }
         stop_metric "tripleo.${STABLE_RELEASE:-master}.${TOCI_JOBTYPE}.overcloud.settle.seconds"
    fi
fi

if [ -f ~/overcloudrc ]; then
    source ~/overcloudrc
fi

if [ "$OVERCLOUD_MAJOR_UPGRADE" == 1 ] ; then
    # Re-enable the delorean-ci repo, as ZUUL_REFS,
    # and thus the contents of delorean-ci may contain packages
    # we want to test for the current branch on upgrade
    if [ -s /etc/nodepool/sub_nodes_private ]; then
      for ip in $(cat /etc/nodepool/sub_nodes_private); do
        ssh $SSH_OPTIONS -tt -i /etc/nodepool/id_rsa $ip \
          sudo sed -i -e \"s/enabled=0/enabled=1/\" /etc/yum.repos.d/delorean-ci.repo
      done
    fi

    source ~/stackrc
    # Set deploy args for stable deployment:
    # We have to use the backward compatible
    if [ ! -z $UPGRADE_ENV ]; then
        export OVERCLOUD_DEPLOY_ARGS="$OVERCLOUD_DEPLOY_ARGS -e $UPGRADE_ENV"
    fi
    # update-from-deployed-server-$UPGRADE_RELEASE.yaml environment when upgrading from
    # $UPGRADE_RELEASE.
    export OVERCLOUD_DEPLOY_ARGS="$UPGRADE_OVERCLOUD_DEPLOY_ARGS -e /usr/share/openstack-tripleo-heat-templates/environments/deployed-server-environment.yaml -e /usr/share/openstack-tripleo-heat-templates/environments/services/sahara.yaml"
    if [ "$UPGRADE_RELEASE" == "newton" ]; then
        export OVERCLOUD_DEPLOY_ARGS="$OVERCLOUD_DEPLOY_ARGS -e /usr/share/openstack-tripleo-heat-templates/environments/updates/update-from-deployed-server-$UPGRADE_RELEASE.yaml"
    fi
    if [ ! -z $UPGRADE_ENV ]; then
        export OVERCLOUD_DEPLOY_ARGS="$OVERCLOUD_DEPLOY_ARGS -e $UPGRADE_ENV"
    fi
    echo_vars_to_deploy_env
    if [ "$MULTINODE" = "1" ]; then
        /usr/share/openstack-tripleo-heat-templates/deployed-server/scripts/get-occ-config.sh 2>&1 | sudo dd of=/var/log/deployed-server-os-collect-config-22.log &
    fi
    # We run basic sanity tests before/after, which includes creating some resources which
    # must survive the upgrade.  The upgrade is performed in two steps, even though this
    # is an all-in-one test, as this is close to how a real deployment with computes would
    # be upgraded.
    $TRIPLEO_ROOT/tripleo-ci/scripts/tripleo.sh --overcloud-sanity --skip-sanitytest-cleanup
    $TRIPLEO_ROOT/tripleo-ci/scripts/tripleo.sh --overcloud-upgrade
    $TRIPLEO_ROOT/tripleo-ci/scripts/tripleo.sh --overcloud-sanity --skip-sanitytest-create --skip-sanitytest-cleanup
    $TRIPLEO_ROOT/tripleo-ci/scripts/tripleo.sh --overcloud-upgrade-converge
    $TRIPLEO_ROOT/tripleo-ci/scripts/tripleo.sh --overcloud-sanity --skip-sanitytest-create
fi

if [ $CA_SERVER == 1 ] ; then
    source ~/overcloudrc

    # Verify that the domain exists
    openstack domain show $LDAP_DOMAIN_NAME

    # Add admin role to admin user for freeipadomain
    openstack role add admin --domain $LDAP_DOMAIN_NAME --user admin --user-domain Default

    # Verify we can access the users in the given domain
    openstack user list --domain $LDAP_DOMAIN_NAME

    # Add demo project to domain
    openstack project create demo --domain $LDAP_DOMAIN_NAME

    # Add admin role to user for that project
    openstack role add admin --project demo --project-domain $LDAP_DOMAIN_NAME \
        --user demo --user-domain $LDAP_DOMAIN_NAME

    # Create rc file for demo user
    cat <<EOF >~/overcloudrc.demouser
# Clear any old environment that may conflict.
for key in \$( set | awk '{FS="="}  /^OS_/ {print \$1}' ); do unset \$key ; done
export OS_USERNAME=demo
export OS_USER_DOMAIN_NAME=$LDAP_DOMAIN_NAME
export OS_PROJECT_DOMAIN_NAME=$LDAP_DOMAIN_NAME
export OS_BAREMETAL_API_VERSION=1.29
export NOVA_VERSION=1.1
export OS_PROJECT_NAME=demo
export OS_PASSWORD=$DEMO_USER_PASS
export OS_NO_CACHE=True
export COMPUTE_API_VERSION=1.1
export no_proxy=,overcloud.$TRIPLEO_DOMAIN,overcloud.ctlplane.$TRIPLEO_DOMAIN,overcloud.$TRIPLEO_DOMAIN,overcloud.ctlplane.$TRIPLEO_DOMAIN
export OS_CLOUDNAME=overcloud
export OS_AUTH_URL=https://overcloud.$TRIPLEO_DOMAIN:13000/v3
export IRONIC_API_VERSION=1.29
export OS_IDENTITY_API_VERSION=3
export OS_AUTH_TYPE=password
export PYTHONWARNINGS="ignore:Certificate has no, ignore:A true SSLContext object is not available"
EOF

    # Tell tripleo.sh/pingtest to use demouserrc instead of overcloudrc. Note
    # that we don't include the $HOME path prefix on the variable, as this is
    # implicitly added in tripleo.sh
    export ALT_OVERCLOUDRC=overcloudrc.demouser
fi

if [ $RUN_PING_TEST == 1 ] ; then
    start_metric "tripleo.${STABLE_RELEASE:-master}.${TOCI_JOBTYPE}.overcloud.ping_test.seconds"
    OVERCLOUD_PINGTEST_OLD_HEATCLIENT=0 $TRIPLEO_ROOT/tripleo-ci/scripts/tripleo.sh --overcloud-pingtest $OVERCLOUD_PINGTEST_ARGS
    stop_metric "tripleo.${STABLE_RELEASE:-master}.${TOCI_JOBTYPE}.overcloud.ping_test.seconds"
fi
if [ $RUN_TEMPEST_TESTS == 1 ] ; then
    start_metric "tripleo.${STABLE_RELEASE:-master}.${TOCI_JOBTYPE}.overcloud.tempest.seconds"
    export TEMPEST_REGEX='^(?=(.*smoke))(?!('
    export TEMPEST_REGEX="${TEMPEST_REGEX}tempest.scenario.test_volume_boot_pattern" # http://bugzilla.redhat.com/1272289
    export TEMPEST_REGEX="${TEMPEST_REGEX}|tempest.api.identity.*v3" # https://bugzilla.redhat.com/1266947
    export TEMPEST_REGEX="${TEMPEST_REGEX}|.*test_external_network_visibility" # https://bugs.launchpad.net/tripleo/+bug/1577769
    export TEMPEST_REGEX="${TEMPEST_REGEX}|tempest.api.data_processing" # Sahara is not enabled by default and has problem with performance
    export TEMPEST_REGEX="${TEMPEST_REGEX}))"
    bash $TRIPLEO_ROOT/tripleo-ci/scripts/tripleo.sh --run-tempest
    stop_metric "tripleo.${STABLE_RELEASE:-master}.${TOCI_JOBTYPE}.overcloud.tempest.seconds"
fi
if [ $TEST_OVERCLOUD_DELETE -eq 1 ] ; then
    source ~/stackrc
    $TRIPLEO_ROOT/tripleo-ci/scripts/tripleo.sh --overcloud-delete
fi

# Upgrade part
if [ "$UNDERCLOUD_MAJOR_UPGRADE" == 1 ] ; then
    # Reset or unset STABLE_RELEASE so that we upgrade to the next major
    # version
    if [ "$STABLE_RELEASE" = "pike" ]; then
        # TODO: switch STABLE_RELEASE to queens when released
        export STABLE_RELEASE=""
    elif [ "$STABLE_RELEASE" = "ocata" ]; then
        export STABLE_RELEASE="pike"
    elif [ "$STABLE_RELEASE" = "mitaka" ]; then
        export STABLE_RELEASE="newton"
    elif [ "$STABLE_RELEASE" = "newton" ]; then
        export STABLE_RELEASE="ocata"
    fi
    echo_vars_to_deploy_env
    # Add the delorean ci repo so that we include the package being tested
    layer_ci_repo
    $TRIPLEO_ROOT/tripleo-ci/scripts/tripleo.sh --undercloud-upgrade 2>&1 | awk '{ print strftime("%Y-%m-%d %H:%M:%S.000"), "|", $0; fflush(); }' | sudo dd of=/var/log/undercloud_upgrade.txt || (tail -n 50 /var/log/undercloud_upgrade.txt && false)
fi
