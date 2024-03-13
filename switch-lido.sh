#!/bin/bash

print_usage() {
  echo "You must provide 1 argument, lido number to switch to."
  echo "Usage: $0 <lido-number: can either be 1 or 2 or 3>"
  exit 1
}

set_variables() {
  WORK_DIR=$(dirname "$(readlink -f "${BASH_SOURCE}")")
  BASTION_USERNAME=$(cat /etc/cmf/bastion_username)
  SSH_KEY_DIR=$(cat /etc/cmf/ssh_keys)
  COPY_LIDO="$1"

  read -p "Enter AWS_PROFILE, if not provided will use [default]: " AWS_PROFILE
  AWS_PROFILE=${AWS_PROFILE:-default}

  read -p "Enter AWS_DEFAULT_REGION, if not provided will use [us-east-2]: " AWS_DEFAULT_REGION
  AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-us-east-2}
}

copy_files() {
  rm -rf config/ backend.conf terraform.tfvars prometheus-custom.yml promtail-lokiurl.yml 
  # rm -rf .terraform*

  cp -r ../lido-keys/lido$COPY_LIDO/config .
  cp ../lido-keys/lido$COPY_LIDO/backend.conf .
  cp ../lido-keys/lido$COPY_LIDO/terraform.tfvars .
  cp ../lido-keys/lido$COPY_LIDO/prometheus-remoteurl.yml ./prometheus-custom.yml
  cp ../lido-keys/lido$COPY_LIDO/promtail-lokiurl.yml .
}

update_ssh_key_path() {
  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' "s#/home/yorick/.ssh#$SSH_KEY_DIR#g" terraform.tfvars
  elif [[ "$(uname)" == "Linux" ]]; then
    sed -i "s#/home/yorick/.ssh#$SSH_KEY_DIR#g" terraform.tfvars
  fi
}

update_ssh_extra_args() {
  bastion_host="infra-bastion-ca.cryptomanufaktur.net"

  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' "s/^ssh_extra_args = .*/ssh_extra_args = \"-o ProxyCommand=\\\\\"bash -c 'cloudflared access ssh-gen --hostname $bastion_host; ssh -W %h:%p $BASTION_USERNAME@cfpipe-$bastion_host'\\\\\" -oPreferredAuthentications=publickey\"/" terraform.tfvars
  elif [[ "$(uname)" == "Linux" ]]; then
    sed -i "s/^ssh_extra_args = .*/ssh_extra_args = \"-o ProxyCommand=\\\\\"bash -c 'cloudflared access ssh-gen --hostname $bastion_host; ssh -W %h:%p $BASTION_USERNAME@cfpipe-$bastion_host'\\\\\" -oPreferredAuthentications=publickey\"/" terraform.tfvars
  fi
}

switch_terraform() {
  ./kill-old-ssh.sh

  # Terraform
  terraform init -backend-config=backend.conf -reconfigure -upgrade
}

main() {
  if [ $# -ne 1 ]; then
    print_usage
  fi

  set_variables "$@"
  copy_files
  update_ssh_key_path
  update_ssh_extra_args

  switch_terraform

  echo "You now need to execute the following commands if not already done so."
  echo
  echo "export AWS_PROFILE='$AWS_PROFILE' && export AWS_DEFAULT_REGION='$AWS_DEFAULT_REGION'"
}

main "$@"
