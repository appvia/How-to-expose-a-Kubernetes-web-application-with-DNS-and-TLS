# How to expose a Kubernetes web app with DNS and TLS

A production-ready application needs to be discoverable and accessible over a secure endpoint, and it can be both complex and time consuming to implement a solution that is easy to consume, maintain and scale. This tutorial brings a few tools together to publish your Kubernetes applications securely, and offers up an easier solution to reduce some of these complexities.

Apart from that [browsers are marking websites that don't use HTTPs as insecure](https://blog.google/products/chrome/milestone-chrome-security-marking-http-not-secure/) which could have a reputational/trust impact on your website/application you might be wondering why you should use HTTPS? We think Cloud Flare's explanation of [Why Use HTTPS?](https://www.cloudflare.com/en-gb/learning/ssl/why-use-https/) is excellent, also Google's [Chrome Dev Summit 2016, Real Talk about HTTPS](https://www.youtube.com/watch?v=iP75a1Y9saY)

What we're using in this tutorial…

- [Amazon EKS cluster](https://aws.amazon.com/eks/)
- [Nginx Ingress Controller](https://kubernetes.github.io/ingress-nginx/)
- [cert-manager](https://cert-manager.io/docs/)
- [external-dns](https://github.com/kubernetes-sigs/external-dns)
- [Amazon route53](https://aws.amazon.com/route53/)
- [Amazon Elastic Network Load Balancer](https://aws.amazon.com/elasticloadbalancing/network-load-balancer/)

## Getting started

> You’ll find the accompanying code for this post in [github.com/appvia/How-to-expose-a-Kubernetes-web-application-with-DNS-and-TLS](https://github.com/appvia/How-to-expose-a-Kubernetes-web-application-with-DNS-and-TLS)

We’ll start with a vanilla [Amazon EKS](https://aws.amazon.com/eks/) cluster, which we can automate with some terraform magic to provide a 3 node cluster.

First, make a main.tf with:

```terraform
// ./main.tf
provider "aws" {}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnet_ids" "default" {
  vpc_id = data.aws_vpc.default.id
}

module "eks" {
  source           = "terraform-aws-modules/eks/aws"
  cluster_name     = "appvia-dns-tls-demo"
  cluster_version  = "1.19"
  subnets          = data.aws_subnet_ids.default.ids
  write_kubeconfig = true
  vpc_id           = data.aws_vpc.default.id
  enable_irsa      = true

  workers_group_defaults = {
    root_volume_type = "gp2"
  }

  worker_groups = [
    {
      name                 = "worker-group"
      instance_type        = "t3a.small"
      asg_desired_capacity = 3
    }
  ]
}

data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_id
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}
```

Then apply that with terraform:

```bash
$ terraform init
Initializing modules...
[...]
Terraform has been successfully initialized!
$ terraform apply
[...]
Apply complete! Resources: 27 added, 0 changed, 0 destroyed.
```

Terraform will helpfully provide a [kubeconfig](https://kubernetes.io/docs/tasks/access-application-cluster/configure-access-multiple-clusters/) file for you to use with kubectl, you can set that to be used for your terminal session without effecting any other configuration you have already set up. By default its name is based on the cluster name, so in the case of our example it's `./kubeconfig_appvia-dns-tls-demo`

```bash
export KUBECONFIG=${PWD}/kubeconfig_appvia-dns-tls-demo
```

When you want to get back to your Kubernetes config:

```bash
unset KUBECONFIG
```

Test that everything is working:

```bash
$ kubectl get pods -A -o wide
NAMESPACE     NAME                       READY   STATUS    RESTARTS   AGE   IP              NODE                                          NOMINATED NODE   READINESS GATES
kube-system   aws-node-qscpx             1/1     Running   0          18m   172.31.12.14    ip-172-31-12-14.eu-west-2.compute.internal    <none>           <none>
kube-system   aws-node-t5qp5             1/1     Running   0          17m   172.31.40.85    ip-172-31-40-85.eu-west-2.compute.internal    <none>           <none>
kube-system   aws-node-zk2gj             1/1     Running   0          18m   172.31.31.122   ip-172-31-31-122.eu-west-2.compute.internal   <none>           <none>
kube-system   coredns-6fd5c88bb9-5f72v   1/1     Running   0          21m   172.31.26.209   ip-172-31-31-122.eu-west-2.compute.internal   <none>           <none>
kube-system   coredns-6fd5c88bb9-zc48s   1/1     Running   0          21m   172.31.8.192    ip-172-31-12-14.eu-west-2.compute.internal    <none>           <none>
kube-system   kube-proxy-647rk           1/1     Running   0          18m   172.31.12.14    ip-172-31-12-14.eu-west-2.compute.internal    <none>           <none>
kube-system   kube-proxy-6gjvt           1/1     Running   0          18m   172.31.31.122   ip-172-31-31-122.eu-west-2.compute.internal   <none>           <none>
kube-system   kube-proxy-6lvnn           1/1     Running   0          17m   172.31.40.85    ip-172-31-40-85.eu-west-2.compute.internal    <none>           <none>

$ kubectl get nodes
NAME                                          STATUS   ROLES    AGE   VERSION
ip-172-31-12-14.eu-west-2.compute.internal    Ready    <none>   17m   v1.19.6-eks-49a6c0
ip-172-31-31-122.eu-west-2.compute.internal   Ready    <none>   17m   v1.19.6-eks-49a6c0
ip-172-31-40-85.eu-west-2.compute.internal    Ready    <none>   17m   v1.19.6-eks-49a6c0
```

You should see a few pods running and three ready nodes:

### [external-dns](https://github.com/kubernetes-sigs/external-dns)

We're going to use [external-dns](https://github.com/kubernetes-sigs/external-dns) to configure a [route53](https://aws.amazon.com/route53/) zone for you, [external-dns](https://github.com/kubernetes-sigs/external-dns) assumes that you've already got a hosted zone in your account that you can use. Mine's set up for `sa-team.teams.kore.appvia.io` so that I can publicly resolve `anything.sa-team.teams.kore.appvia.io`.

To let [external-dns](https://github.com/kubernetes-sigs/external-dns) make changes to the [route53](https://aws.amazon.com/route53/) zone, we can do that with an [IAM role](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles.html) and attach that to a [service account](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/).

```terraform
// ./iam_roles.tf
data "aws_iam_policy_document" "externaldns_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:external-dns:external-dns"]
    }

    principals {
      identifiers = [module.eks.oidc_provider_arn]
      type        = "Federated"
    }
  }
}

data "aws_iam_policy_document" "externaldns_role" {
  statement {
    effect    = "Allow"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["route53:ListHostedZones", "route53:ListResourceRecordSets"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "externaldns_route53" {
  assume_role_policy = data.aws_iam_policy_document.externaldns_assume.json
  name               = "externaldns_route53"
  inline_policy {
    name   = "externaldns_role"
    policy = data.aws_iam_policy_document.externaldns_role.json
  }
}
```

Then apply that:

```bash
$ terraform apply
[...]
Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
```

You'll see that it's bound to a service account called `external-dns` in the `external-dns` [namespace](https://kubernetes.io/docs/tasks/administer-cluster/namespaces/). Now, let's test that all of that works as it should.

First, check the current state:

```bash
$ kubectl run -i --restart=Never --image amazon/aws-cli $(uuid) -- sts get-caller-identity
{
    "UserId": "AROARZYWN37USPQWOL5XC:i-0633eb78d38a31643",
    "Account": "123412341234",
    "Arn": "arn:aws:sts::123412341234:assumed-role/appvia-dns-tls-demo20210323123032764000000009/i-0633eb78d38a31643"
}
```

You'll see the `UserId` and `Arn` have have an `i-...` in, which is the node instance (this won't have access to much).

Now, make an `outputs.tf` to provide an easy way to get the AWS account ID:

```terraform
// ./output.tf
data "aws_caller_identity" "current" {}

output "aws_account_id" {
  value = data.aws_caller_identity.current.account_id
}
```

Refresh the terraform state and create the namespace and service account:

```bash
$ terraform refresh
[...]
Outputs:
aws_account_id = "123412341234"

$ kubectl create namespace external-dns
namespace/external-dns created

$ kubectl create -n external-dns serviceaccount external-dns
serviceaccount/external-dns created

$ kubectl annotate serviceaccount -n external-dns external-dns eks.amazonaws.com/role-arn=arn:aws:iam::$(terraform output -raw aws_account_id):role/externaldns_route53
serviceaccount/external-dns annotated

$ kubectl run -i -n external-dns --restart=Never --image amazon/aws-cli $(uuid) -- sts get-caller-identity
{
    "UserId": "AROARZYWN37USAHEEKT35:botocore-session-1123456767",
    "Account": "123412341234",
    "Arn": "arn:aws:sts::123412341234:assumed-role/externaldns_route53/botocore-session-1123456767"
}
```

Notice how the `Arn` has `assumed-role/externaldns_route53` in it to show that you've successfully assumed the role.

Deploy external-dns:

```bash
$ kubectl -n external-dns apply -k "github.com/kubernetes-sigs/external-dns/kustomize?ref=v0.7.6"
serviceaccount/external-dns configured
clusterrole.rbac.authorization.k8s.io/external-dns created
clusterrolebinding.rbac.authorization.k8s.io/external-dns-viewer created
deployment.apps/external-dns created
```

We need to patch the default configuration, so start by creating a `k8s/external-dns/deployment.yaml`:

```yaml
# ./k8s/external-dns/deployment.yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: external-dns
spec:
  template:
    spec:
      containers:
        - name: external-dns
          args:
            - --source=ingress
            - --provider=aws
            - --registry=txt
            - --txt-owner-id=external-dns
            - --aws-zone-type=public
```

Then apply the patch:

```bash
$ kubectl -n external-dns patch deployments.apps external-dns --patch-file k8s/external-dns/deployment.yaml
deployment.apps/external-dns patched
```

The configuration above will set [external-dns](https://github.com/kubernetes-sigs/external-dns) to look for hostnames in the ingress configuration and create a record for them that points to the ingress controller's load balancer.

### [ingress-nginx](https://kubernetes.github.io/ingress-nginx/)

We're going to use [ingress-nginx](https://kubernetes.github.io/ingress-nginx/) to get us going. Other ingress options are available - you might want to consider other options depending on your specific needs; see [Comparison of Kubernetes Ingress controllers](https://docs.google.com/spreadsheets/d/191WWNpjJ2za6-nbG4ZoUMXMpUK8KlCIosvQB0f-oq3k/)

Now, deploy [ingress-nginx](https://kubernetes.github.io/ingress-nginx/). This configuration is set up to request an [Amazon Elastic Network Load Balancer](https://aws.amazon.com/elasticloadbalancing/network-load-balancer/) and attach it to the ingress controller:

```bash
$ kubectl apply -k "github.com/kubernetes/ingress-nginx.git/deploy/static/provider/aws?ref=controller-v0.44.0"
namespace/ingress-nginx created
validatingwebhookconfiguration.admissionregistration.k8s.io/ingress-nginx-admission created
serviceaccount/ingress-nginx-admission created
serviceaccount/ingress-nginx created
role.rbac.authorization.k8s.io/ingress-nginx-admission created
role.rbac.authorization.k8s.io/ingress-nginx created
clusterrole.rbac.authorization.k8s.io/ingress-nginx-admission created
clusterrole.rbac.authorization.k8s.io/ingress-nginx created
rolebinding.rbac.authorization.k8s.io/ingress-nginx-admission created
rolebinding.rbac.authorization.k8s.io/ingress-nginx created
clusterrolebinding.rbac.authorization.k8s.io/ingress-nginx-admission created
clusterrolebinding.rbac.authorization.k8s.io/ingress-nginx created
configmap/ingress-nginx-controller created
service/ingress-nginx-controller-admission created
service/ingress-nginx-controller created
deployment.apps/ingress-nginx-controller created
job.batch/ingress-nginx-admission-create created
job.batch/ingress-nginx-admission-patch created
```

This works totally out the box, but you might need to scale the deployment if you want some resilience. Let's go with three replicas for now:

```bash
$ kubectl scale -n ingress-nginx --replicas=3 deployment ingress-nginx-controller
deployment.apps/ingress-nginx-controller scaled
```

### [cert-manager](https://cert-manager.io/docs/)

Now we need to deploy [cert-manager](https://cert-manager.io):

[cert-manager](https://cert-manager.io) is going to handle populating a secret, adjacent to our ingress configuration, with a valid TLS certificate that we're going to configure to come from [Lets Encrypt](https://letsencrypt.org/) using the [ACME protocol](https://tools.ietf.org/html/rfc8555) though [cert-manager](https://cert-manager.io) which supports a number of [different issuer types](https://cert-manager.io/docs/configuration/):

```bash
$ kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.2.0/cert-manager.yaml
customresourcedefinition.apiextensions.k8s.io/certificaterequests.cert-manager.io created
customresourcedefinition.apiextensions.k8s.io/certificates.cert-manager.io created
customresourcedefinition.apiextensions.k8s.io/challenges.acme.cert-manager.io created
customresourcedefinition.apiextensions.k8s.io/clusterissuers.cert-manager.io created
customresourcedefinition.apiextensions.k8s.io/issuers.cert-manager.io created
customresourcedefinition.apiextensions.k8s.io/orders.acme.cert-manager.io created
namespace/cert-manager created
serviceaccount/cert-manager-cainjector created
serviceaccount/cert-manager created
serviceaccount/cert-manager-webhook created
clusterrole.rbac.authorization.k8s.io/cert-manager-cainjector created
clusterrole.rbac.authorization.k8s.io/cert-manager-controller-issuers created
clusterrole.rbac.authorization.k8s.io/cert-manager-controller-clusterissuers created
clusterrole.rbac.authorization.k8s.io/cert-manager-controller-certificates created
clusterrole.rbac.authorization.k8s.io/cert-manager-controller-orders created
clusterrole.rbac.authorization.k8s.io/cert-manager-controller-challenges created
clusterrole.rbac.authorization.k8s.io/cert-manager-controller-ingress-shim created
clusterrole.rbac.authorization.k8s.io/cert-manager-view created
clusterrole.rbac.authorization.k8s.io/cert-manager-edit created
clusterrolebinding.rbac.authorization.k8s.io/cert-manager-cainjector created
clusterrolebinding.rbac.authorization.k8s.io/cert-manager-controller-issuers created
clusterrolebinding.rbac.authorization.k8s.io/cert-manager-controller-clusterissuers created
clusterrolebinding.rbac.authorization.k8s.io/cert-manager-controller-certificates created
clusterrolebinding.rbac.authorization.k8s.io/cert-manager-controller-orders created
clusterrolebinding.rbac.authorization.k8s.io/cert-manager-controller-challenges created
clusterrolebinding.rbac.authorization.k8s.io/cert-manager-controller-ingress-shim created
role.rbac.authorization.k8s.io/cert-manager-cainjector:leaderelection created
role.rbac.authorization.k8s.io/cert-manager:leaderelection created
role.rbac.authorization.k8s.io/cert-manager-webhook:dynamic-serving created
rolebinding.rbac.authorization.k8s.io/cert-manager-cainjector:leaderelection created
rolebinding.rbac.authorization.k8s.io/cert-manager:leaderelection created
rolebinding.rbac.authorization.k8s.io/cert-manager-webhook:dynamic-serving created
service/cert-manager created
service/cert-manager-webhook created
deployment.apps/cert-manager-cainjector created
deployment.apps/cert-manager created
deployment.apps/cert-manager-webhook created
mutatingwebhookconfiguration.admissionregistration.k8s.io/cert-manager-webhook created
validatingwebhookconfiguration.admissionregistration.k8s.io/cert-manager-webhook created
```

We need to create a couple of issuers, we're going to use [Lets Encrypt](https://letsencrypt.org/) [HTTP-01](https://letsencrypt.org/docs/challenge-types/#http-01-challenge).

Replace the `user@example.com` with your email address in both issuers, this allows [Lets Encrypt](https://letsencrypt.org/) to send you [email notifications](https://letsencrypt.org/docs/expiration-emails/) if your certificate is due to expire and hasn't been automatically renewed or removed:

```yaml
# ./k8s/cert-manager/issuers.yaml
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    email: user@example.com
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - http01:
          ingress: {}
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    email: user@example.com
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
      - http01:
          ingress: {}
```

Then apply that:

```bash
$ kubectl apply -f ./k8s/cert-manager/issuers.yaml
clusterissuer.cert-manager.io/letsencrypt-prod created
clusterissuer.cert-manager.io/letsencrypt-staging created
```

## Bringing it all together

We're going to deploy a three replica [simple helloworld application](https://hub.docker.com/r/nginxdemos/hello/) with a Service and an Ingress.

```yaml
# ./k8s/myapp.yaml
---
kind: Deployment
apiVersion: apps/v1
metadata:
  name: helloworld
  labels:
    name: helloworld
spec:
  replicas: 3
  selector:
    matchLabels:
      name: helloworld
  template:
    metadata:
      labels:
        name: helloworld
    spec:
      containers:
        - image: nginxdemos/hello
          resources:
            limits:
              memory: 32Mi
              cpu: 1000m
          name: helloworld
          ports:
            - name: http
              containerPort: 80
          livenessProbe:
            httpGet:
              path: /
              port: http
      restartPolicy: Always
---
apiVersion: v1
kind: Service
metadata:
  name: helloworld
spec:
  ports:
    - name: http
      port: 8080
      targetPort: http
  selector:
    name: helloworld
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: helloworld
  annotations:
    kubernetes.io/tls-acme: 'true'
    certmanager.k8s.io/cluster-issuer: letsencrypt-prod
spec:
  tls:
    - hosts:
        - dns-tls-demo.sa-team.teams.kore.appvia.io
      secretName: helloworld
  rules:
    - host: dns-tls-demo.sa-team.teams.kore.appvia.io
      http:
        paths:
          - pathType: Prefix
            path: '/'
            backend:
              service:
                name: helloworld
                port:
                  name: http
```

Change the references to `dns-tls-demo.sa-team.teams.kore.appvia.io` to something within your zone, in line with what you did in the [external-dns](#external-dns) configuration.

This will cause [external-dns](https://github.com/kubernetes-sigs/external-dns) to create a record in your [route53](https://aws.amazon.com/route53/) zone to point to the [ingress-nginx](https://kubernetes.github.io/ingress-nginx/)) controller's [network load balancer](https://aws.amazon.com/elasticloadbalancing/network-load-balancer/) and [cert-manager](https://cert-manager.io/docs/) to retrieve a valid certificate for that.

You can test this all with:

```bash
$ nslookup dns-tls-demo.sa-team.teams.kore.appvia.io
Server:		1.1.1.1
Address:	1.1.1.1#53

Name:	dns-tls-demo.sa-team.teams.kore.appvia.io
Address: 18.135.204.171

$ curl https://dns-tls-demo.sa-team.teams.kore.appvia.io
<!DOCTYPE html>
<html>
<head>
<title>Hello World</title>
[...]
</body>
</html>
```

## Tear down

The order you destroy things is **REALLY IMPORTANT** to not leave [orphaned resources](https://docs.aws.amazon.com/eks/latest/userguide/delete-cluster.html) behind that could be costly. For example, if you `terraform destroy` before removing the `ingress` configuration and `ingress-nginx` you'll likely leave behind both a [route53 A record](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/rrsets-working-with.html), which if you're creating and destroying regularly could incur costs if you end up with over `10,000` records (which will happen faster than you think). And also a [Load Balancer](https://aws.amazon.com/elasticloadbalancing/network-load-balancer/) which could cost just under \$30/month.

To do it in order:

```
$ kubectl delete ingress --all -A
ingress.extensions "helloworld" deleted
$ kubectl delete namespaces ingress-nginx
namespace "ingress-nginx" deleted
$ terraform state rm module.eks.kubernetes_config_map.aws_auth #workaround https://github.com/terraform-aws-modules/terraform-aws-eks/issues/1162
Removed module.eks.kubernetes_config_map.aws_auth[0]
Successfully removed 1 resource instance(s).
$ terraform destroy -force
[...]
Destroy complete! Resources: 27 destroyed.
$ unset KUBECONFIG
```

## Conclusion

With the amount of effort involved in doing this there are plenty of pitfalls and risks (specifically orphaned resource cost) that will likely mean most teams will end up with a long lived [snowflake setup](https://martinfowler.com/bliki/SnowflakeServer.html) aka a pet, but you thought you were doing devops.
[Kore Operate](https://www.appvia.io/kore-operate) manages the complexity of the services that help in securing and exposing applications, in addition to providing a UI to create an ingress API object, making it easy for devs.

---

## References

- https://blog.atomist.com/kubernetes-ingress-nginx-cert-manager-external-dns/
- https://github.com/kubernetes-sigs/external-dns/tree/master/docs/tutorials
- https://medium.com/asl19-developers/use-lets-encrypt-cert-manager-and-external-dns-to-publish-your-kubernetes-apps-to-your-website-ff31e4e3badf
- https://github.com/kubernetes/ingress-nginx/tree/master/docs/user-guide
- https://github.com/appvia/kore-app-example
