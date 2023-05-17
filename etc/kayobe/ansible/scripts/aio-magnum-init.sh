#!/bin/bash

set -o errexit
set -o pipefail

KOLLA_OPENSTACK_COMMAND=${KOLLA_OPENSTACK_COMMAND:-openstack}
IMAGE_PATH='./'

if [[ $KOLLA_DEBUG -eq 1 ]]; then
  set -o xtrace
  KOLLA_OPENSTACK_COMMAND="$KOLLA_OPENSTACK_COMMAND --debug"
fi

if ! $KOLLA_OPENSTACK_COMMAND flavor list | grep -q ds2G20; then
  echo Creating flavor ds2G20 for ubuntu image
  $KOLLA_OPENSTACK_COMMAND flavor create ds2G20 --ram 2048 --disk 20 --id d5 --vcpus 2 --public
fi


if ! $KOLLA_OPENSTACK_COMMAND image list | grep -q ubuntu-2004-kube-v1.26.0; then
  echo Downloading ubuntu k8s image..

  curl -L --fail -o ${IMAGE_PATH}ubuntu-2004-kube-v1.26.3.qcow2 https://object.arcus.openstack.hpc.cam.ac.uk/swift/v1/AUTH_f0dc9cb312144d0aa44037c9149d2513/azimuth-images-prerelease/ubuntu-focal-kube-v1.26.3-230411-1504.qcow2
  $KOLLA_OPENSTACK_COMMAND image create ubuntu-2004-kube-v1.26.3 \
    --file ${IMAGE_PATH}/ubuntu-2004-kube-v1.26.3.qcow2 \
    --disk-format qcow2 \
    --container-format bare \
    --public
  $KOLLA_OPENSTACK_COMMAND image set ubuntu-2004-kube-v1.26.3 --os-distro ubuntu --os-version 20.04 --property kube_version="v1.26.3"

  echo Registering new driver template..

  $KOLLA_OPENSTACK_COMMAND coe cluster template create new_driver \
  --coe kubernetes \
  --image ubuntu-2004-kube-v1.26.3 \
  --external-network public1 \
  --label kube_tag=v1.26.3 \
  --master-flavor ds2G20 \
  --flavor ds2G20 \
  --public \
  --master-lb-enabled
  
fi

#old driver
if ! $KOLLA_OPENSTACK_COMMAND image list | grep -q fedora-coreos-35.20220116.3.0-openstack.x86_64; then
  echo Downloading fedora image...
  curl -L --fail -o ${IMAGE_PATH}/fedora-coreos-35.20220116.3.0-openstack.x86_64.qcow2.xz  https://builds.coreos.fedoraproject.org/prod/streams/stable/builds/35.20220116.3.0/x86_64/fedora-coreos-35.20220116.3.0-openstack.x86_64.qcow2.xz
  unxz ${IMAGE_PATH}/fedora-coreos-35.20220116.3.0-openstack.x86_64.qcow2.xz
  
  $KOLLA_OPENSTACK_COMMAND image create fedora-coreos-35.20220116.3.0-openstack.x86_64 \
    --file ${IMAGE_PATH}/fedora-coreos-35.20220116.3.0-openstack.x86_64.qcow2 \
    --disk-format qcow2 \
    --container-format bare \
    --public
  $KOLLA_OPENSTACK_COMMAND image set fedora-coreos-35.20220116.3.0-openstack.x86_64 --os-distro fedora-coreos

  echo Creating old driver template...
  $KOLLA_OPENSTACK_COMMAND coe cluster template create old_driver \
    --coe kubernetes \
    --image fedora-coreos-35.20220116.3.0-openstack.x86_64 \
    --external-network public1 \
    --master-flavor m1.medium \
    --flavor m1.medium \
    --public 
fi 

#setup octavia management network to be reachable from control plane 
# if ! $KOLLA_OPENSTACK_COMMAND router list | grep -q lb-rtr; then
#   echo Ensuring control plane access to octavia network...
#   $KOLLA_OPENSTACK_COMMAND router create lb-rtr --disable-snat --external-gateway public1
#   $KOLLA_OPENSTACK_COMMAND router add subnet lb-rtr lb-mgmt-subnet
#   $KOLLA_OPENSTACK_COMMAND network set lb-mgmt-net --share
#   ROUTER_IP=$($KOLLA_OPENSTACK_COMMAND router show lb-rtr -f json | jq '.external_gateway_info.external_fixed_ips[].ip_address')
#   SUBNET_CIDR=$($KOLLA_OPENSTACK_COMMAND subnet show lb-mgmt-subnet -f json | jq '.cidr')

#   eval sudo ip r add $SUBNET_CIDR via $ROUTER_IP
# fi

touch /tmp/.init-runonce-mgm