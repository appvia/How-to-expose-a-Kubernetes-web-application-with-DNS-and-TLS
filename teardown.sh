#!/bin/bash
export KUBECONFIG=./kubeconfig_appvia-dns-tls-demo
kubectl delete namespace myapp ingress-nginx 
sleep 10 # give the dns records and load balancer to be removed
kustomize build . | kubectl delete -f -

terraform state rm module.eks.kubernetes_config_map.aws_auth #workaround https://github.com/terraform-aws-modules/terraform-aws-eks/issues/1162

terraform destroy -force