#!groovy
import groovy.transform.Field;

@Field final DNS_ZONE = ".k8s.local"

properties([
  [$class: 'ParametersDefinitionProperty',
    parameterDefinitions: [
      stringParameter("AwsAccessKeyID","Amazon AWS Access Key ID to use AWS CLI commands (using the SDKs) and using AWS API operations."),
      stringParameter("AwsSecretAccessKey","Amazon AWS Secret Key to use AWS CLI commands (using the SDKs) and using AWS API operations."),
      stringParameter("AwsDefaultRegion","Amazon AWS Default to use AWS CLI commands (using the SDKs) and using AWS API operations.","us-west-2"),
      stringParameter("KubernetesClusterName","Provide de cluster name to be created.","siltest"),
      stringParameter("S3BucketName","Dedicated unique S3 Bucket to store the state of your cluster, and the representation of cluster. It will be created if not exists. Bucket names need to be unique."),
      stringParameter("Zones", "Zones in which to run the cluster. If more than one, separate them with commas","us-west-2a"),
      stringParameter("MasterInstanceType","Instance type (size) for masters EC2 instance","m3.large"),
      stringParameter("MasterCount","Number of masters cluster EC2 instance", "1"),
      stringParameter("NodesInstanceType","Instance type (size) for nodes EC2 instance","m3.large"),
      stringParameter("NodesCount","Number of nodes cluster EC2 instance", "3"),
      stringParameter("NodesMinSize","Set the minimum number of nodes desired (auto scaling)", "1"),
      stringParameter("NodesMaxSize","Set the maximum number of nodes desired (auto scaling)", "5"),
      stringParameter("PublicKey","SSH Public Key"),
      stringParameter("AmiImage","Image used for all EC2 Instances"),
      stringParameter("VpcID","Provide de ID of shared VPC","vpc-f3fd0498"),
      stringParameter("NetworkCIDR","The Network CIDR from VPC provided before","10.44.0.0/16"),
      stringParameter("SubnetIDs","Provide de shared subnets ids (private). If more than one, separate them with commas"),
      stringParameter("UtilitySubnetIDs","Provide de shared utility subnets ids (private). If more than one, separate them with commas"),
      stringParameter("NameServer","(DNS) Enter the Internet address of a name server that the resolver should query, either an IPv4 address (in dot notation)")
    ]
  ]
])

def stringParameter(name, description, defaultValue="") {
  return [ name: name, description: description, $class: 'StringParameterDefinition', defaultValue: defaultValue]
}

def updateTemplateVariables(templateName, varMap) {
  def txt = readFile file: templateName
  for (e in varMap) {
      txt = txt.replace("#{"+e.key+"}", e.value)
  }
  return txt
}

def createValuesFile() {
  fileName = "${WORKSPACE}/kubernetes/config/values.properties"
  writeFile file: fileName, text: updateTemplateVariables("${WORKSPACE}/kubernetes/templates/values.tpl", [
    _AWS_DEFAULT_REGION_    : params.AwsDefaultRegion,
    _AMI_IMAGE_             : params.AmiImage,
    _S3_BUCKET_NAME_        : params.S3BucketName,
    _KOPS_CLUSTER_NAME_     : params.KubernetesClusterName,
    _SSH_PUBLIC_KEY_        : "key.pub",
    _MASTER_COUNT_          : params.MasterCount,
    _NODES_COUNT_           : params.NodesCount,
    _MASTER_TYPE_           : params.MasterInstanceType,
    _NODES_TYPE_            : params.NodesInstanceType,
    _ZONES_                 : params.Zones,
    _NODES_MIN_SIZE_        : params.NodesMinSize,
    _NODES_MAX_SIZE_        : params.NodesMaxSize,
    _VPC_ID_                : params.VpcID,
    _NETWORK_CIDR_          : params.NetworkCIDR,
    _SUBNET_IDS_            : params.SubnetIDs,
    _UTILITY_SUBNET_IDS_    : params.UtilitySubnetIDs
  ])
}

def kubernetesCluster(Map args) {
  switch(args.action) {
    case 'preview':
      sh 'echo $PWD'
      sh "bash kops.sh preview-cluster"
      sh "bash kops.sh delete-cluster"
      break
    case 'create':
      sh 'echo $PWD'
      sh "bash kops.sh create-cluster"
      break
  }

}

def createDNSConfigMap() {
  filename = "${WORKSPACE}/kubernetes/kube-dns-cm.yaml"
  writeFile file: filename, text: updateTemplateVariables("${WORKSPACE}/kubernetes/templates/kube-dns-cm.tpl", [
    _DNS_NAMESERVER_ : params.NameServer
  ])
}

def getMasterInstanceId(kopsClusterName) {
  masterInstanceId = sh ( script: """
      aws ec2 describe-instances --filters Name=tag:Name,Values=*masters.${kopsClusterName} 'Name=instance-state-name,Values=running' \
      --query 'Reservations[0].Instances[0].InstanceId' \
      --output text
    """,
    returnStdout: true).trim()

  return masterInstanceId
}

def isKubernetesMasterReady(masterInstanceId) {
  def instanceStatuses = sh (script: "aws ec2 describe-instance-status --instance-ids ${masterInstanceId}", returnStdout: true)
  def instanceStatusesJSON = readJSON text: instanceStatuses
  def status = instanceStatusesJSON.InstanceStatuses
  return (status.SystemStatus.Status[0] == "ok" && status.InstanceStatus.Status[0] == "ok")
}

node() {
  kopsClusterName = "${params.KubernetesClusterName}${DNS_ZONE}"
  stage('Checkout') {
    checkout scm
  }

  withEnv(["AWS_ACCESS_KEY_ID=${params.AwsAccessKeyID}", "AWS_SECRET_ACCESS_KEY=${params.AwsSecretAccessKey}",
    "AWS_DEFAULT_REGION=${params.AwsDefaultRegion}"]) {
    dir('kubernetes') {

      stage('Cluster Preview') {
        try {
          createValuesFile()
          writeFile file: "${WORKSPACE}/kubernetes/config/ssh/key.pub", text: params.PublicKey
          kubernetesCluster(action: 'preview')
        } catch(err) {
          error 'Could not validate the cluster. Try again.'
        }
      }

      stage('Cluster Creation') {
        input message: 'Approve cluster creation?'
        kubernetesCluster(action: 'create')
      }

      stage ('Kubernetes DNS Configuration') {
        println 'Waiting Kubernetes master to be ready... '
        try {
          def masterInstanceId = "None"
          timeout(time: 5, unit: 'MINUTES') {
            waitUntil {
              masterInstanceId = getMasterInstanceId(kopsClusterName)
              return masterInstanceId != "None"
            }
          }
        } catch(err) {
          error 'EC2 Instance master not found.'
        }

        try {
          timeout(time: 10, units: 'MINUTES') {
            waitUntil {
              return isKubernetesMasterReady(masterInstanceId)
            }
            println "Kubernetes master is up and running."
          }
        } catch(err) {
            error "This probably means something wrong happened. Review whether your nodes came up properly before trying again."
        }

        println "Applying DNS ConfigMap..."
        try {
          createDNSConfigMap()
          timeout(time: 5, unit: 'MINUTES') {
            waitUntil {
              def statusCode = sh (script: 'kubectl create -f kube-dns-cm.yaml', returnStatus: true)
              return statusCode == 0
            }
            sh 'kubectl delete pod -l k8s-app=kube-dns -n kube-system'
          }
        } catch(err) {
          error 'Could not apply the DNS settings to the cluster.'
        }

        println "Configure tiller"
        sh "kubectl apply -f 1link-tiller-setup.yaml"
        sh "helm init --service-account tiller --tiller-namespace 1link"

        try {
          timeout(time: 5, unit: 'MINUTES') {
            waitUntil {
              def statusCode = sh (script: 'kubectl cluster-info', returnStatus: true)
              return statusCode == 0
            }
          }
        } catch(err) {
          error 'Sorry, kubernentes cluster Timeout...'
        }
      }
    }
  }
}
