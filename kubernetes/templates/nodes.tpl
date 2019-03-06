apiVersion: kops/v1alpha2
kind: InstanceGroup
metadata:
  labels:
    kops.k8s.io/cluster: ${KOPS_CLUSTER_NAME}
  name: nodes
spec:
  image: ${AMI_IMAGE}
  machineType: ${NODES_TYPE}
  minSize: ${NODES_MIN_SIZE}
  maxSize: ${NODES_MAX_SIZE}
  nodeLabels:
    kops.k8s.io/instancegroup: nodes
  role: Node