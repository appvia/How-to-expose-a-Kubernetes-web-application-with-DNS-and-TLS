#!/bin/bash
terraform apply -auto-approve
export KUBECONFIG=./kubeconfig_appvia-dns-tls-demo
kustomize build . | kubectl apply -f -
kubectl get pods -A

kubectl annotate serviceaccount -n external-dns external-dns eks.amazonaws.com/role-arn=arn:aws:iam::$(terraform output -raw aws_account_id):role/externaldns_route53