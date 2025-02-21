#!/bin/bash
set -o errexit
set -o pipefail


KOLLA_DEBUG=${KOLLA_DEBUG:-0}

KOLLA_OPENSTACK_COMMAND=${KOLLA_OPENSTACK_COMMAND:-openstack}

if [[ $KOLLA_DEBUG -eq 1 ]]; then
    set -o xtrace
    KOLLA_OPENSTACK_COMMAND="$KOLLA_OPENSTACK_COMMAND --debug"
fi

# This script is meant to be run once after running start for the first
# time.  This script downloads a cirros image and registers it.  Then it
# configures networking and nova quotas to allow 40 m1.small instances
# to be created.

ARCH=$(uname -m)
IMAGE_PATH=/opt/cache/files/
IMAGE_URL=https://github.com/cirros-dev/cirros/releases/download/0.5.1/
IMAGE=cirros-0.5.1-${ARCH}-disk.img
IMAGE_NAME=cirros
IMAGE_TYPE=linux

# This EXT_NET_CIDR is your public network,that you want to connect to the internet via.
ENABLE_EXT_NET=${ENABLE_EXT_NET:-1}
EXT_NET_CIDR=${EXT_NET_CIDR:-'10.0.2.0/24'}
EXT_NET_RANGE=${EXT_NET_RANGE:-'start=10.0.2.150,end=10.0.2.199'}
EXT_NET_GATEWAY=${EXT_NET_GATEWAY:-'10.0.2.1'}

# Sanitize language settings to avoid commands bailing out
# with "unsupported locale setting" errors.
unset LANG
unset LANGUAGE
LC_ALL=C
export LC_ALL
for i in curl "$KOLLA_OPENSTACK_COMMAND"; do
    if [[ ! $(type ${i} 2>/dev/null) ]]; then
        if [ "${i}" == 'curl' ]; then
            echo "Please install ${i} before proceeding"
        else
            echo "Please install python-${i}client before proceeding"
        fi
        exit
    fi
done

# Test for credentials set
if [[ "${OS_USERNAME}" == "" ]]; then
    echo "No Keystone credentials specified. Try running source /etc/kolla/admin-openrc.sh command"
    exit
fi

# Test to ensure configure script is run only once
if $KOLLA_OPENSTACK_COMMAND image list | grep -q cirros; then
    echo "This tool should only be run once per deployment."
    exit
fi

echo Checking for locally available cirros image.
# Let's first try to see if the image is available locally
# nodepool nodes caches them in $IMAGE_PATH
if ! [ -f "${IMAGE_PATH}/${IMAGE}" ]; then
    IMAGE_PATH='./'
    if ! [ -f "${IMAGE_PATH}/${IMAGE}" ]; then
        echo None found, downloading cirros image.
        curl --fail -L -o ${IMAGE_PATH}/${IMAGE} ${IMAGE_URL}/${IMAGE}
    fi
else
    echo Using cached cirros image from the nodepool node.
fi

echo Creating glance image.
$KOLLA_OPENSTACK_COMMAND image create --disk-format qcow2 --container-format bare --public \
    --property os_type=${IMAGE_TYPE} --file ${IMAGE_PATH}/${IMAGE} ${IMAGE_NAME}

echo Configuring neutron.

$KOLLA_OPENSTACK_COMMAND router create demo-router

$KOLLA_OPENSTACK_COMMAND network create demo-net
$KOLLA_OPENSTACK_COMMAND subnet create --subnet-range 10.0.0.0/24 --network demo-net \
    --gateway 10.0.0.1 --dns-nameserver 8.8.8.8 demo-subnet
$KOLLA_OPENSTACK_COMMAND router add subnet demo-router demo-subnet

if [[ $ENABLE_EXT_NET -eq 1 ]]; then
    $KOLLA_OPENSTACK_COMMAND network create --external --provider-physical-network physnet1 \
        --provider-network-type flat public1
    $KOLLA_OPENSTACK_COMMAND subnet create --no-dhcp \
        --allocation-pool ${EXT_NET_RANGE} --network public1 \
        --subnet-range ${EXT_NET_CIDR} --gateway ${EXT_NET_GATEWAY} public1-subnet
    $KOLLA_OPENSTACK_COMMAND router set --external-gateway public1 demo-router
fi

# Get admin user and tenant IDs
ADMIN_USER_ID=$($KOLLA_OPENSTACK_COMMAND user list | awk '/ admin / {print $2}')
ADMIN_PROJECT_ID=$($KOLLA_OPENSTACK_COMMAND project list | awk '/ admin / {print $2}')
ADMIN_SEC_GROUP=$($KOLLA_OPENSTACK_COMMAND security group list --project ${ADMIN_PROJECT_ID} | awk '/ default / {print $2}')

# Sec Group Config
$KOLLA_OPENSTACK_COMMAND security group rule create --ingress --ethertype IPv4 \
    --protocol icmp ${ADMIN_SEC_GROUP}
$KOLLA_OPENSTACK_COMMAND security group rule create --ingress --ethertype IPv4 \
    --protocol tcp --dst-port 22 ${ADMIN_SEC_GROUP}
# Open heat-cfn so it can run on a different host
$KOLLA_OPENSTACK_COMMAND security group rule create --ingress --ethertype IPv4 \
    --protocol tcp --dst-port 8000 ${ADMIN_SEC_GROUP}
$KOLLA_OPENSTACK_COMMAND security group rule create --ingress --ethertype IPv4 \
    --protocol tcp --dst-port 8080 ${ADMIN_SEC_GROUP}

if [ ! -f ~/.ssh/id_rsa.pub ]; then
    echo Generating ssh key.
    ssh-keygen -t rsa -N '' -f ~/.ssh/id_rsa
fi
if [ -r ~/.ssh/id_rsa.pub ]; then
    echo Configuring nova public key and quotas.
    $KOLLA_OPENSTACK_COMMAND keypair create --public-key ~/.ssh/id_rsa.pub mykey
fi

# Increase the quota to allow 40 m1.small instances to be created

# 40 instances
$KOLLA_OPENSTACK_COMMAND quota set --instances 40 ${ADMIN_PROJECT_ID}

# 40 cores
$KOLLA_OPENSTACK_COMMAND quota set --cores 40 ${ADMIN_PROJECT_ID}

# 96GB ram
$KOLLA_OPENSTACK_COMMAND quota set --ram 96000 ${ADMIN_PROJECT_ID}

# add default flavors, if they don't already exist
if ! $KOLLA_OPENSTACK_COMMAND flavor list | grep -q m1.tiny; then
    $KOLLA_OPENSTACK_COMMAND flavor create --id 1 --ram 512 --disk 1 --vcpus 1 m1.tiny
    $KOLLA_OPENSTACK_COMMAND flavor create --id 2 --ram 2048 --disk 20 --vcpus 1 m1.small
    $KOLLA_OPENSTACK_COMMAND flavor create --id 3 --ram 4096 --disk 40 --vcpus 2 m1.medium
    $KOLLA_OPENSTACK_COMMAND flavor create --id 4 --ram 8192 --disk 80 --vcpus 4 m1.large
    $KOLLA_OPENSTACK_COMMAND flavor create --id 5 --ram 16384 --disk 160 --vcpus 8 m1.xlarge
fi

# Configure IP routing and NAT to allow VMs to reach the outside world
iface=$(ip route | awk '$1 == "default" {print $5; exit}')
sudo iptables -A POSTROUTING -t nat -o $iface -j MASQUERADE
sudo sysctl -w net.ipv4.conf.all.forwarding=1

touch /tmp/.init-runonce
