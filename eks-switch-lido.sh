#!/bin/bash

print_usage() {
  if [ $# -ne 3 ]; then
    echo "You must provide 3 arguments, lido number to switch to, bastion username and SSH keys directory."
    echo "Usage: $0 <bastion_username> <ssh_keys_dir: e.g ~/.ssh/ssh-keys> <lido-number: 1/2/3>"
    exit 1
  fi
}

set_variables() {
  WORK_DIR=$(dirname "$(readlink -f "${BASH_SOURCE}")")
  BASTION_USERNAME="$1"
  SSH_KEY_DIR=$(readlink -f "${2}")
  COPY_LIDO="$3"
}

copy_files() {
  rm -rf config/ backend.conf terraform.tfvars prometheus-custom.yml promtail-lokiurl.yml 
  rm -rf .terraform*

  cp -r ../lido-config/lido$COPY_LIDO/config .
  cp ../lido-config/lido$COPY_LIDO/backend.conf .
  cp ../lido-config/lido$COPY_LIDO/terraform.tfvars .
  cp ../lido-config/lido$COPY_LIDO/prometheus-custom.yml ./prometheus-custom.yml
  cp ../lido-config/lido$COPY_LIDO/promtail-lokiurl.yml .
}

update_ssh_key_path() {
  if [[ "$(uname)" == "Darwin" ]]; then
    sed -i '' "s#^ssh_private_key = .*#ssh_private_key = \"$SSH_KEY_DIR/cmf-east-2.pem\"#" terraform.tfvars
  elif [[ "$(uname)" == "Linux" ]]; then
    sed -i "s#^ssh_private_key = .*#ssh_private_key = \"$SSH_KEY_DIR/cmf-east-2.pem\"#" terraform.tfvars
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

  # switch kubectl context
  ./switch-terraform.sh
}

get_aws_details() {
  read -p "Enter AWS_PROFILE, if not provided will use [admin]: " AWS_PROFILE
  AWS_PROFILE=${AWS_PROFILE:-admin}

  bucket_region=$(grep '^region' backend.conf | awk -F '"' '{print $2}')
  bastion_region=$(grep -A 2 'bastion' terraform.tfvars | grep 'region' | awk -F '"' '{print $2}' | tr -d '\n')

  if [ $bucket_region == $bastion_region ]; then
    read -p "Enter AWS_DEFAULT_REGION, default if not provided is bucket/bastion region [$bucket_region]: " AWS_DEFAULT_REGION
  else
    read -p "Enter AWS_DEFAULT_REGION, bucket region [$bucket_region] is different from bastion region [$bastion_region]. Enter correct region, will use bucket region if not provided: " AWS_DEFAULT_REGION
  fi

  AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION:-$bucket_region}
}

main() {
  print_usage "$@"

  set_variables "$@"
  copy_files
  get_aws_details
  update_ssh_key_path
  update_ssh_extra_args

  switch_terraform

  echo
  echo "-------------------------------------------------------------------------------------------------------"
  echo "You now need to execute the following commands to change aws variables. NB Confirm this matches the region of s3 bucket and kubectl bastion otherwise errors occur."
  echo
  echo "export AWS_PROFILE='$AWS_PROFILE' && export AWS_DEFAULT_REGION='$AWS_DEFAULT_REGION'"
  echo
  echo
  echo "-------------------------------------------------------------------------------------------------------"

}

main "$@"
