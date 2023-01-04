#!/bin/bash

set -euo pipefail

function main () {

    generate_ca_cert
    generate_simple_certs
    generate_kubelet_certs
    generate_api_server_cert
    generate_kubeconfig_files
    genereate_encrypttion_config_file
    upload_controller_files
    upload_worker_files
}

function generate_ca_cert () {
  cfssl gencert -initca ca-csr.json | cfssljson -bare ca	
}

function generate_simple_certs () {
  # These can be generated without provisioning the cluster

  local -r cert_names=("admin" "kube-controller-manager" "kube-proxy" "kube-scheduler" "service-account")

  for cert_name in "${cert_names[@]}"; do
    cfssl gencert \
      -ca=ca.pem \
      -ca-key=ca-key.pem \
      -config=ca-config.json \
      -profile=kubernetes \
      "${cert_name}-csr.json" | cfssljson -bare "${cert_name}"
  done

}

function generate_kubelet_certs () {

  for i in 0 1 2; do
    instance="worker-${i}"
    instance_hostname="ip-10-2-1-2${i}"
    cat > ${instance}-csr.json <<EOF
{
  "CN": "system:node:${instance_hostname}",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:nodes",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

    external_ip=$(aws ec2 describe-instances --profile k8splay --filters \
      "Name=tag:Name,Values=${instance}" \
      "Name=instance-state-name,Values=running" \
      --output text --query 'Reservations[].Instances[].PublicIpAddress')

    internal_ip=$(aws ec2 describe-instances --profile k8splay --filters \
      "Name=tag:Name,Values=${instance}" \
      "Name=instance-state-name,Values=running" \
      --output text --query 'Reservations[].Instances[].PrivateIpAddress')

    cfssl gencert \
      -ca=ca.pem \
      -ca-key=ca-key.pem \
      -config=ca-config.json \
      -hostname=${instance_hostname},${external_ip},${internal_ip} \
      -profile=kubernetes \
      worker-${i}-csr.json | cfssljson -bare worker-${i}
  done
}


function generate_api_server_cert () {

  KUBERNETES_HOSTNAMES=kubernetes,kubernetes.default,kubernetes.default.svc,kubernetes.default.svc.cluster,kubernetes.svc.cluster.local
  KUBERNETES_PUBLIC_ADDRESS=$(aws elbv2 describe-load-balancers --profile k8splay\
   --names "k8splay-api" --output text --query 'LoadBalancers[].DNSName')

  cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -hostname=10.32.0.1,10.2.1.10,10.2.1.11,10.2.1.12,${KUBERNETES_PUBLIC_ADDRESS},127.0.0.1,${KUBERNETES_HOSTNAMES} \
  -profile=kubernetes \
  kubernetes-csr.json | cfssljson -bare kubernetes

}

function generate_kubeconfig_files () {

  KUBERNETES_PUBLIC_ADDRESS=$(aws elbv2 describe-load-balancers --profile k8splay\
   --names "k8splay-api" --output text --query 'LoadBalancers[].DNSName')

  for instance in worker-0 worker-1 worker-2; do
    generate_kubeconfig_file "$instance" "system:node:" "https://${KUBERNETES_PUBLIC_ADDRESS}:443"
  done

  generate_kubeconfig_file "kube-proxy" "system:" "https://${KUBERNETES_PUBLIC_ADDRESS}:443"
  generate_kubeconfig_file "kube-controller-manager" "system:" "https://127.0.0.1:6443"
  generate_kubeconfig_file "kube-scheduler" "system:" "https://127.0.0.1:6443"
  generate_kubeconfig_file "admin" "" "https://127.0.0.1:6443"

}

function generate_kubeconfig_file () {

  NAME=$1
  USERPREFIX=$2  # must end with : if not empty
  SERVER_URL=$3

  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.pem \
    --embed-certs=true \
    --server="${SERVER_URL}" \
    --kubeconfig="${NAME}.kubeconfig"

  kubectl config set-credentials ${USERPREFIX}${NAME} \
    --client-certificate="${NAME}.pem" \
    --client-key="${NAME}-key.pem" \
    --embed-certs=true \
    --kubeconfig="${NAME}.kubeconfig"

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user="${USERPREFIX}${NAME}" \
    --kubeconfig="${NAME}.kubeconfig"

  kubectl config use-context default --kubeconfig="${NAME}.kubeconfig"

}

function genereate_encrypttion_config_file () {

  ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)

  cat > encryption-config.yaml <<EOF
kind: EncryptionConfig
apiVersion: v1
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${ENCRYPTION_KEY}
      - identity: {}
EOF
}


function upload_controller_files () {

  for instance in controller-0 controller-1 controller-2; do
  external_ip=$(aws ec2 describe-instances --profile k8splay --filters \
    "Name=tag:Name,Values=${instance}" \
    "Name=instance-state-name,Values=running" \
    --output text --query 'Reservations[].Instances[].PublicIpAddress')
  
  scp -i ~/k8splay_rsa \
      ca.pem ca-key.pem \
      kubernetes-key.pem kubernetes.pem \
      service-account-key.pem service-account.pem \
      admin.kubeconfig \
      kube-controller-manager.kubeconfig \
      kube-scheduler.kubeconfig \
      encryption-config.yaml \
    "ubuntu@${external_ip}:~/"
done

}

function upload_worker_files () {

  for instance in worker-0 worker-1 worker-2; do
    external_ip=$(aws ec2 describe-instances --profile k8splay --filters \
      "Name=tag:Name,Values=${instance}" \
      "Name=instance-state-name,Values=running" \
      --output text --query 'Reservations[].Instances[].PublicIpAddress')

  scp -i ~/k8splay_rsa \
      ca.pem \
      ${instance}-key.pem ${instance}.pem \
      ${instance}.kubeconfig \
      kube-proxy.kubeconfig \
    "ubuntu@${external_ip}:~/"
  done	

}

main "$@"