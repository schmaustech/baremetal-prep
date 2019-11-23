#!/usr/bin/env bash
#################################################################
# Script Prepares Provisioning Node For OpenShift Deployment    #
#################################################################

howto(){
  echo "Usage: ./baremetal-prep.sh -p <provisioning interface> -b <baremetal interface> -d (configure for disconnected) -g (generate install-config.yaml)"
  echo "Example: ./baremetal-prep.sh -p ens3 -b ens4 -d -g"
}


set_opts(){
  ENABLEDISCONNECT=0
  GENERATEINSTALLCONF=0
  while getopts p:b:dgh option
  do
  case "${option}"
  in
  p) PROV_CONN=${OPTARG};;
  b) MAIN_CONN=${OPTARG};;
  d) ENABLEDISCONNECT=1;;
  g) GENERATEINSTALLCONF=1;;
  h) howto; exit 0;;
  \?) howto; exit 1;;
  esac
  done

  if ([ -z "$PROV_CONN" ] || [ -z "$MAIN_CONN" ]) then
   howto
   exit 1
  fi
}


disable_selinux(){
  echo -n "Disabling selinux..."
  sudo setenforce permissive >/dev/null 2>&1
  sudo sed -i "s/=enforcing/=permissive/g" /etc/selinux/config >/dev/null 2>&1
  echo "Success!"

}

setup_default_pool(){
  if `sudo virsh pool-info default >/dev/null 2>&1`; then
    echo "Default pool exists...Skipping!"
  else
    echo -n "Creating default pool..."
    sudo virsh pool-define-as --name default --type dir --target /var/lib/libvirt/images
    sudo virsh pool-start default
    sudo virsh pool-autostart default
    sudo usermod --append --groups libvirt $USERNAME
    echo "Success!"
  fi
}

setup_repository(){
  sudo yum -y install podman httpd httpd-tools
  sudo mkdir -p /opt/registry/{auth,certs,data}
  sudo openssl req -newkey rsa:4096 -nodes -sha256 -keyout /opt/registry/certs/domain.key -x509 -days 365 -out /opt/registry/certs/domain.crt -subj "/C=US/ST=Massachussetts/L=Boston/O=Red Hat/OU=Engineering/CN=$HOST_URL"
  sudo cp /opt/registry/certs/domain.crt $HOME/domain.crt
  sudo chown $USERNAME:$USERNAME $HOME/domain.crt
  sudo cp /opt/registry/certs/domain.crt /etc/pki/ca-trust/source/anchors/
  sudo update-ca-trust extract
  sudo htpasswd -bBc /opt/registry/auth/htpasswd dummy dummy
  sudo firewall-cmd --add-port=5000/tcp --zone=libvirt  --permanent
  sudo firewall-cmd --add-port=5000/tcp --zone=public   --permanent
  sudo firewall-cmd --add-service=http  --permanent
  sudo firewall-cmd --reload
  sudo podman create --name poc-registry -p 5000:5000 -v /opt/registry/data:/var/lib/registry:z -v /opt/registry/auth:/auth:z -e "REGISTRY_AUTH=htpasswd" -e "REGISTRY_AUTH_HTPASSWD_REALM=Registry" -e "REGISTRY_HTTP_SECRET=ALongRandomSecretForRegistry" -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd -v /opt/registry/certs:/certs:z -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/domain.crt -e REGISTRY_HTTP_TLS_KEY=/certs/domain.key docker.io/library/registry:2
  sudo podman start poc-registry
  mirror_images()
  update_installconfig()
}

update_installconfig(){
  echo "Updating install-config.yaml..."
  sed -i -e 's/^/  /' $HOME/domain.crt
  sed  -i '/^pullSecret/d' $HOME/install-config.yaml
  echo "pullSecret: '{ \"auths\": { \"$HOST_URL:5000\": {\"auth\": \"ZHVtbXk6ZHVtbXk=\",\"email\": \"$USERNAME@redhat.com\"} } }'" >> $HOME/install-config.yaml
  echo "additionalTrustBundle: |" >> $HOME/install-config.yaml
  cat $HOME/domain.crt >> $HOME/install-config.yaml
  echo "imageContentSources:" >> $HOME/install-config.yaml
  echo "- mirrors:" >> $HOME/install-config.yaml
  echo "  - $HOST_URL:5000/ocp4/openshift4" >> $HOME/install-config.yaml
  echo "  source: registry.svc.ci.openshift.org/ocp/$NEW_RELEASE" >> $HOME/install-config.yaml
  echo "- mirrors:" >> $HOME/install-config.yaml
  echo "  - $HOST_URL:5000/ocp4/openshift4" >> $HOME/install-config.yaml
  echo "  source: registry.svc.ci.openshift.org/ocp/release" >> $HOME/install-config.yaml

}

mirror_images(){
  echo "Mirroring remote repository to local respository..."
  /usr/local/bin/oc adm release mirror -a $LOCAL_SECRET_JSON --from=$UPSTREAM_REPO --to-release-image=$LOCAL_REG/$LOCAL_REPO:$OCP_RELEASE --to=$LOCAL_REG/$LOCAL_REPO
}

setup_env(){
  echo "Setting environment..."
  HOST_URL=`hostname -f`
  HOME=/home/`whoami`
  USERNAME=`whoami`
  LATEST_CI_IMAGE=$(curl https://openshift-release.svc.ci.openshift.org/api/v1/releasestream/4.3.0-0.ci/latest | grep -o 'registry.svc.ci.openshift.org[^"]\+')
  OPENSHIFT_RELEASE_IMAGE="${OPENSHIFT_RELEASE_IMAGE:-$LATEST_CI_IMAGE}"
  GOPATH=$HOME/go
  OCP_RELEASE=`echo $LATEST_CI_IMAGE|cut -d: -f2`
  NEW_RELEASE=`echo $OCP_RELEASE|sed s/.0-0.ci//g`
  UPSTREAM_REPO=$LATEST_CI_IMAGE
  LOCAL_REG="${HOST_URL}:5000"
  LOCAL_REPO='ocp4/openshift4'
  LOCAL_SECRET_JSON="${HOME}/pull-secret.json"
  OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${LOCAL_REG}/${LOCAL_REPO}:${OCP_RELEASE}
}

setup_bridges(){
  if `ip a|egrep "baremetal|provisioning"`; then
    echo "A baremetal or provisioning interface already exists...Skipping!"
  else
    echo "Setting up baremetal and provisioning bridges..."
    sudo nmcli connection add ifname provisioning type bridge con-name provisioning
    sudo nmcli con add type bridge-slave ifname "$PROV_CONN" master provisioning
    sudo nmcli connection add ifname baremetal type bridge con-name baremetal
    sudo nmcli con add type bridge-slave ifname "$MAIN_CONN" master baremetal
    sudo nmcli con down "System $MAIN_CONN";sudo pkill dhclient;sudo dhclient baremetal
    sudo nmcli connection modify provisioning ipv4.addresses 172.22.0.1/24 ipv4.method manual
    sudo nmcli con down provisioning
    sudo nmcli con up provisioning
  fi
}

install_depends(){
  echo "Installing required dependencies..."
  sudo yum -y install ansible git usbredir golang libXv virt-install libvirt libvirt-devel libselinux-utils qemu-kvm mkisofs 
}

setup_installconfig(){
  echo "Creating install-config.yaml..."
  /usr/bin/ansible-playbook -i hosts make-install-config.yml
}

set_opts
setup_env
install_depends
disable_selinux
setup_default_pool
setup_bridges
setup_installconfig
setup_repository
exit