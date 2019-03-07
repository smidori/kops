#!/usr/bin/env bash

export action="$1"
export user_properties_file="./config/values.properties"

function error() {
  echo "[`date +'%Y-%m-%d %H:%M:%S'`][ERROR] $@" 2>&1
}

function info() {
  echo "[`date +'%Y-%m-%d %H:%M:%S'`] $@" 2>&1
}

function env-subst() {
eval "cat <<EOF
$(cat)
EOF
" 2> /dev/null
}

function kops-usage(){
  echo ""
  echo "Usage of Kops script:"
  echo $'\t'"./kops.sh create-cluster    : Create a kubernetes cluster and cloud based resources using command line flags"
  echo $'\t'"./kops.sh validate-cluster  : Validates a few kops cluster components"
  echo $'\t'"./kops.sh delete-cluster    : Delete de cluster and cloud resources managed by kops. WARNING: It can not be undone"
  echo $'\t'"./kops.sh rolling-update    : Updates a kubernetes cluster to match the cloud and kops specifications. INFO: It can take some time"
  echo $'\t'"./kops.sh update-worker     : Update workers replacing a resources desired configuration by node template"
  echo ""
  echo $'\t'"./kops.sh preview-cluster   : Preview kubernetes cluster and cloud based resources"
  echo $'\t'"./kops.sh terraform-cluster : Create an terraform output for cluster and cloud based resources"
  echo ""
  exit;
}

function s3-bucket-check() {
  info "Check S3 Storage \"${KOPS_STATE_STORE}\""
  bucket=${S3_BUCKET_NAME}
  bucket_check=$(aws s3api head-bucket --bucket $bucket 2>&1)

  if [[ -z $bucket_check ]]; then
    info "S3 Bucket ${bucket} already exists."
  else
    info "Creating S3 Bucket ${bucket} in the ${AWS_DEFAULT_REGION}..."
    if [[ ${AWS_DEFAULT_REGION} == "us-east-1" ]]; then
      aws s3api create-bucket --bucket ${bucket} --region ${AWS_DEFAULT_REGION}
    else
      aws s3api create-bucket --bucket ${bucket} --region ${AWS_DEFAULT_REGION} --create-bucket-configuration LocationConstraint=${AWS_DEFAULT_REGION}
    fi
  fi
}

function s3-bucket-delete {
  info "Delete S3 Storage \"${KOPS_STATE_STORE}\""
  bucket=${S3_BUCKET_NAME}
  bucket_check=$(aws s3api head-bucket --bucket $bucket 2>&1)

  if [[ -z $bucket_check ]]; then
    if [[ ! $(kops get cluster) ]]; then
      aws s3 rm ${KOPS_STATE_STORE} --recursive
      aws s3 rb ${KOPS_STATE_STORE} --force
    else
      error "S3 Bucket ${bucket} is in use."
    fi
  else
    error "S3 Bucket ${bucket} not found."
  fi
}

if [[ ! -f ${user_properties_file} ]] ; then
  cat <<EOF
You must create the following file:
${user_properties_file}

You can start copying the sample:
  ${user_properties_file}.sample

And filling the values as follows as described in the README.md.
EOF

  error "$0 didn't execute. Read instructions."
  exit -1
fi

# Default
export CONFIG_PATH="./config"
export VALUES_FILE="values.properties"
export SSH_PUBLIC_KEY_PATH="${CONFIG_PATH}/ssh"
export PROVIDER="aws"
export DNS_ZONE=".k8s.local"
export NETWORKING="calico"
export TOPOLOGY="private"

# User inputs
source ${CONFIG_PATH}/${VALUES_FILE}
export KOPS_CLUSTER_NAME=${KOPS_CLUSTER_NAME}${DNS_ZONE}
export KOPS_STATE_STORE=s3://${S3_BUCKET_NAME}
export SSH_PUBLIC_KEY=${SSH_PUBLIC_KEY_PATH}/${SSH_PUBLIC_KEY}
export KOPS_UPDATE_TEMPLATE_PATH="./templates"

[ $# -eq 1 ] || kops-usage;

case $action in
  create-cluster)
    info "Create Cluster \"${KOPS_CLUSTER_NAME}\""
    if [[ ! $(kops get cluster) ]]; then
      s3-bucket-check
      info "Create Cluster"
      kops create cluster \
        --cloud ${PROVIDER} \
        --zones ${ZONES} \
        --networking ${NETWORKING} \
        --topology ${TOPOLOGY} \
        --ssh-public-key ${SSH_PUBLIC_KEY} \
        --image=${AMI_IMAGE} \
        --node-count ${NODES_COUNT} \
        --node-size ${NODES_TYPE} \
        --master-count ${MASTER_COUNT} \
        --master-size ${MASTER_TYPE} \
        --vpc ${VPC_ID} \
        --network-cidr ${NETWORK_CIDR} \
        --subnets ${SUBNET_IDS} \
        --utility-subnets ${UTILITY_SUBNET_IDS} \
        --yes
    else
      info "Cluster ${KOPS_CLUSTER_NAME} already exists."
    fi
    ;;
  validate-cluster)
    info "Validate Cluster \"${KOPS_CLUSTER_NAME}\""
    if [[ $(kops get cluster) ]]; then
      kops validate cluster
    else
      error "Cluster \"${KOPS_CLUSTER_NAME}\" doesn't exists. Nothing to do."
      exit 1
    fi
    ;;
  update-cluster)
    info "Update Cluster \"${KOPS_CLUSTER_NAME}\""
    if [[ $(kops get cluster) ]]; then
      info "Exporting kops state to kubeconfig(~/.kube/config)..."
      kops export kubecfg

      info "Updating..."
      kops update cluster --yes
    else
      error "Cluster \"${KOPS_CLUSTER_NAME}\" doesn't exists. Nothing to do."
      exit 1
    fi
    ;;
  delete-cluster)
    info "Delete Cluster \"${KOPS_CLUSTER_NAME}\""
    if [[ $(kops get cluster) ]]; then
      kops delete cluster --yes
    else
      info "Cluster \"${KOPS_CLUSTER_NAME}\" doesn't exists. Nothing to do."
    fi
    ;;
  rolling-update)
    info "Rolling Update \"${KOPS_CLUSTER_NAME}\""
    if [[ $(kops get cluster) ]]; then
        info "Exporting kops state to kubeconfig(~/.kube/config)"
        kops export kubecfg

        info "Rolling update of your cluster \"${KOPS_CLUSTER_NAME}\" will start in a seconds..."
        sleep 3
        kops rolling-update cluster --yes
    else
        error "Cluster \"${KOPS_CLUSTER_NAME}\" doesn't exists. No need to update."
    fi
    ;;
  update-worker)
    info "Update Worker \"${KOPS_CLUSTER_NAME}\""
    if [[ $(kops get cluster) ]]; then
      info "Exporting kops state to kubeconfig(~/.kube/config)"
      kops export kubecfg

      info "Generating nodes yaml from template file"
      cat ${KOPS_UPDATE_TEMPLATE_PATH}/nodes.tpl | env-subst > ${KOPS_UPDATE_TEMPLATE_PATH}/nodes.yaml

      info "Replacing new nodes.yaml with state file in S3: ${S3_BUCKET_NAME}"
      kops replace -f ${KOPS_UPDATE_TEMPLATE_PATH}/nodes.yaml

      info "Updating nodes auto scaling group ${KOPS_CLUSTER_NAME}..."
      kops update cluster --yes
    else
      error "Cluster \"${KOPS_CLUSTER_NAME}\" doesn't exists. No need to update."
    fi
    ;;
  edit-cluster)
    kops edit cluster
    ;;
    preview-cluster)
    info "Preview Cluster \"${KOPS_CLUSTER_NAME}\""
    if [[ ! $(kops get cluster) ]]; then
      s3-bucket-check
      kops create cluster \
        --cloud ${PROVIDER} \
        --zones ${ZONES} \
        --networking ${NETWORKING} \
        --topology ${TOPOLOGY} \
        --ssh-public-key ${SSH_PUBLIC_KEY} \
        --image=${AMI_IMAGE} \
        --node-count ${NODES_COUNT} \
        --node-size ${NODES_TYPE} \
        --master-count ${MASTER_COUNT} \
        --master-size ${MASTER_TYPE} \
        --vpc ${VPC_ID} \
        --network-cidr ${NETWORK_CIDR} \
        --subnets ${SUBNET_IDS} \
        --utility-subnets ${UTILITY_SUBNET_IDS} \
        --output yaml \
        --dry-run
      #s3-bucket-delete
    else
      info "Cluster ${KOPS_CLUSTER_NAME} already exists."
      exit 1
    fi
    ;;
  terraform-cluster)
    info "Kops Terraform"
    if [[ ! $(kops get cluster) ]]; then
      s3-bucket-check
      kops create cluster \
        --cloud ${PROVIDER} \
        --zones ${ZONES} \
        --networking ${NETWORKING} \
        --topology ${TOPOLOGY} \
        --ssh-public-key ${SSH_PUBLIC_KEY} \
        --image=${AMI_IMAGE} \
        --node-count ${NODES_COUNT} \
        --node-size ${NODES_TYPE} \
        --master-count ${MASTER_COUNT} \
        --master-size ${MASTER_TYPE} \
        --vpc ${VPC_ID} \
        --network-cidr ${NETWORK_CIDR} \
        --subnets ${SUBNET_IDS} \
        --utility-subnets ${UTILITY_SUBNET_IDS} \
        --target terraform
    else
      info "Cluster ${KOPS_CLUSTER_NAME} already exists."
    fi
    ;;
  *)
    kops-usage
    ;;
  esac
