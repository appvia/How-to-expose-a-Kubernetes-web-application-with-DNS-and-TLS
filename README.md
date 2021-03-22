# EKS + ingress + dns + tls(le http01)

> Accompanying content for this blog post [How to expose a Kubernetes web application with DNS and TLS](#) _@TODO LINK TBC_

Simple example of deploying:

- [Amazon Elastic Kubernetes Service
  (EKS)](https://aws.amazon.com/eks/)
- [ingress-nginx](https://github.com/kubernetes/ingress-nginx)
- [external-dns](https://github.com/kubernetes-incubator/external-dns)
- [cert-manager](https://github.com/jetstack/cert-manager)

## How to deploy

```bash
$ aws-vault exec kore-sa-team-notprod --server
$ ./run.sh
```

## How to destroy

```bash
$ aws-vault exec kore-sa-team-notprod --server
$ ./teardown.sh
```
