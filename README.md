# springboot-argocd
Springboot CRUD Operation with ArgoCD deployment scripts

## Pre-requisites
1. Install minikube into your local machine. [Installation Guide](https://minikube.sigs.k8s.io/docs/start/)
2. Install kubectl into your local machine.[Installation Guide](https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/)
3. Install helm into your local machine.[Installation Guide](https://helm.sh/docs/intro/install/)
4. Also encourage you to install [kubectx + kubens](https://github.com/ahmetb/kubectx) to navigate Kubernetes easily.

## Vault installation
For the beginning select toolbox namespace.
```text
# namespace for Vault & ArgoCD
kubectl create ns toolbox
kubens toolbox
```
To install Vault we will use the official [Helm chart](https://github.com/hashicorp/vault-helm) provided by HashiCorp.
```text
helm repo add hashicorp https://helm.releases.hashicorp.com
helm install vault hashicorp/vault --set "server.dev.enabled=true"
```
To check if Vault is successfully installed on the Kubernetes cluster we can display a list of running pods:

```text
kubectl get pod 
NAME                                   READY   STATUS    RESTARTS   AGE
vault-0                                1/1     Running   0          25s
vault-agent-injector-9456c6d55-hx2fd   1/1     Running   0          21s
```
we need to enable port-forwarding and export Vault local address as the VAULT_ADDR environment variable:
```text
kubectl port-forward vault-0 8200

git bash
export VAULT_ADDR=http://127.0.0.1:8200
powershell
$env:VAULT_ADDR='http://127.0.0.1:8200'

vault status
vault login root
```
### Vault setup
Vault uses [Secrets Engines](https://developer.hashicorp.com/vault/docs/secrets) to store, generate, or encrypt data. The basic Secret Engine for storing static secrets is [Key-Value](https://developer.hashicorp.com/vault/docs/secrets/kv/kv-v2) engine. Let’s create one sample secret that we’ll inject later into Helm Charts.
```text
# enable kv-v2 engine in Vault
vault secrets enable kv-v2

# create kv-v2 secret with two keys
vault kv put kv-v2/demo user="secret_user" password="secret_password" message="Let AUS win this match"

vault kv put kv-v2/rds_service host="postgres" name="postgres" username="admin" password="admin"

# create policy to enable reading above secret
vault policy write demo - <<EOF
path "kv-v2/data/demo" {
  capabilities = ["read"]
}
EOF

vault policy write rds_service - <<EOF
path "kv-v2/data/rds_service" {
  capabilities = ["read"]
}
EOF
```
Now we need to create a role that will authenticate ArgoCD in Vault. We said that Vault has Secrets Engines component. [Auth methods](https://developer.hashicorp.com/vault/docs/auth) are another type of component in Vault but for assigning identity and a set of policies to user/app. As we are using Kubernetes platforms, we need to focus on [Kubernetes Auth Method](https://developer.hashicorp.com/vault/docs/auth/kubernetes) to configure Vault accesses. Let’s configure this auth method.

```text
# enable Kubernetes Auth Method
vault auth enable kubernetes

# configure Kubernetes Auth Method by logging inside vault container
kubectl exec -it vault-0 sh
vault write auth/kubernetes/config token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443" kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt disable_local_ca_jwt=true
# create authenticate Role for ArgoCD
vault write auth/kubernetes/role/argocd bound_service_account_names=argocd-repo-server bound_service_account_namespaces=toolbox policies=demo,rds_service ttl=200h

# exit out of container
exit

# read configured kubernetes auth method for verification
vault read auth/kubernetes/config

# read configured ArgoCD authenticate Role for verification
vault read auth/kubernetes/role/argocd
```

## Postgres Installation
```text
kubectl apply -f ./infra/postgres/postgres-deployment.yaml
```
## How AVP Works?
![Alt text](avp_how_it_works.png?raw=true "How it works?")

## ArgoCD & Vault Plugin Installation
Time for the main actor of this article - [Argo CD Vault Plugin](https://github.com/argoproj-labs/argocd-vault-plugin) It will be responsible for injecting secrets from the Vault into Helm Charts. In addition to Helm Charts, this plugin can handle secret injections into pure Kubernetes manifests or `Kustomize` templates. Here we will focus only on Helm Charts. Different sources required different installations, which you can find in plugin documentation.

What makes plugin documentation less clear is that it can be installed in two ways:

* Installation via `argocd-cm` ConfigMap (old option, deprecated from version `2.6.0` of ArgoCD)
* Installation via a `sidecar container` (new option, supported from version `2.4.0` of ArgoCD)

Since the old option will be not supported in future releases, I will install the ArgoCD Vault Plugin using a sidecar container. In order to properly install and configure ArgoCD, we need to follow a few steps:

Before all make sure you are still in toolbox namespace where we want to place Vault, ArgoCD, and all stuff for Vault plugin.

```text
kubens toolbox
```
1. Create k8s Secret with authorization configuration that Vault plugin will use.
  ```yaml
   kind: Secret
   apiVersion: v1
   metadata:
     name: argocd-vault-plugin-credentials
   type: Opaque
   stringData:
     AVP_AUTH_TYPE: "k8s"
     AVP_K8S_ROLE: "argocd"
     AVP_TYPE: "vault"
     VAULT_ADDR: "http://vault.toolbox:8200"
   ```
```text
kubectl apply -f ./argocd-installation/argocd-vault-plugin-credentials.yaml
```
2. Create k8s ConfigMap with Vault plugin configuration that will be mounted in the sidecar container, and overwrite default processing of Helm Charts on ArgoCD. Look carefully at this configuration file. Under init command you can see that we add Bitnami Helm repo and execute helm dependency build. It is required if Charts installed by you use dependencies charts. You can customize or get rid of it if your Charts haven’t any dependencies.
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cmp-plugin
data:
  plugin.yaml: |
    apiVersion: argoproj.io/v1alpha1
    kind: ConfigManagementPlugin
    metadata:
      name: argocd-vault-plugin-helm
    spec:
      allowConcurrency: true
      discover:
        find:
          command:
            - sh
            - "-c"
            - "find . -name 'Chart.yaml' && find . -name 'values.yaml'"
      init:
       command:
          - bash
          - "-c"
          - |
            helm repo add bitnami https://charts.bitnami.com/bitnami
            helm dependency build
      generate:
        command:
          - bash
          - "-c"
          - |
            helm template $ARGOCD_APP_NAME -n $ARGOCD_APP_NAMESPACE -f <(echo "$ARGOCD_ENV_HELM_VALUES") . |
            argocd-vault-plugin generate -s toolbox:argocd-vault-plugin-credentials -
      lockRepo: false
```
```text
kubectl apply -f ./argocd-installation/argocd-vault-plugin-cmp.yaml
```
3. Finally, we have to install ArgoCD from the official [Helm Chart](https://github.com/argoproj/argo-helm) but with extra configuration that provides modifications required to install Vault plugin via sidecar container.
```yaml
repoServer:
  rbac:
    - verbs:
        - get
        - list
        - watch
      apiGroups:
        - ''
      resources:
        - secrets
        - configmaps
  initContainers:
    - name: download-tools
      image: registry.access.redhat.com/ubi8
      env:
        - name: AVP_VERSION
          value: 1.11.0
      command: [sh, -c]
      args:
        - >-
          curl -L https://github.com/argoproj-labs/argocd-vault-plugin/releases/download/v$(AVP_VERSION)/argocd-vault-plugin_$(AVP_VERSION)_linux_amd64 -o argocd-vault-plugin &&
          chmod +x argocd-vault-plugin &&
          mv argocd-vault-plugin /custom-tools/
      volumeMounts:
        - mountPath: /custom-tools
          name: custom-tools

  extraContainers:
    - name: avp-helm
      command: [/var/run/argocd/argocd-cmp-server]
      image: quay.io/argoproj/argocd:v2.4.8
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
      volumeMounts:
        - mountPath: /var/run/argocd
          name: var-files
        - mountPath: /home/argocd/cmp-server/plugins
          name: plugins
        - mountPath: /tmp
          name: tmp-dir
        - mountPath: /home/argocd/cmp-server/config
          name: cmp-plugin
        - name: custom-tools
          subPath: argocd-vault-plugin
          mountPath: /usr/local/bin/argocd-vault-plugin

  volumes:
    - configMap:
        name: cmp-plugin
      name: cmp-plugin
    - name: custom-tools
      emptyDir: {}
    - name: tmp-dir
      emptyDir: {}

# If you face issue with ArgoCD CRDs installation, then uncomment below section to disable it
#crds:
#  install: false
```
Save that Helm values as `argocd-helm-values.yaml` and execute below commands:
```text
# once againe make sure to use proper namespace
kubens toolbox

# install ArgoCD with provided vaules
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n toolbox -f ./argocd-installation/argocd-helm-values.yaml

# verify argocd pods are up and running
kubectl get pods
```
Note that argocd-repo-server has sidecar container avp-helm

## Install your resources with secrets injection
To obtain admin user password execute the below command in git bash:
```text
kubectl -n toolbox get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d

# port forwarding in separate terminal window
kubectl port-forward svc/argocd-server 8080:80

# authorize ArgoCD CLI
argocd login localhost:8080 --username admin --password $(kubectl get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
```
Create the new reposistory in docker io and build docker image and push to docker hub.
```text
docker build --tag=springboot-argocd:latest --rm=true .
docker tag springboot-argocd:latest innotigers/springboot-argocd:latest

# verify that able to run this image in local
docker run -it --rm -p 8080:8080 -p 8081:8081 innotigers/springboot-argocd:latest

docker login docker.io
docker push innotigers/springboot-argocd:latest
```


As our demo Chart we will use my debug Spring Boot application from [GitHub repo](https://github.com/prabakaran88/springboot-argocd). It’s simple web server that exposes a few debugging endpoints. Application has Helm templates and ArgoCD Application definition under /infra directory. To deploy this stack to k8s with Argo we need to apply ArgoCD Application CRD. Below full code sample, which you can also explore [here](https://github.com/prabakaran88/springboot-argocd/blob/main/infra/argocd/argocd-application-with-vault-secrets.yaml).
```text
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: springboot-argocd-demo
spec:
  destination:
    namespace: toolbox
    server: https://kubernetes.default.svc
  project: default
  source:
    path: infra/helm
    repoURL: https://github.com/prabakaran88/springboot-argocd
    targetRevision: main
    plugin:
      env:
        - name: HELM_VALUES
          value: |
            serviceAccount:
              create: true
            image:
              repository: innotigers/springboot-argocd
              tag: latest
              pullPolicy: IfNotPresent
            replicaCount: 1
            resources:
              memoryRequest: 256Mi
              memoryLimit: 512Mi
              cpuRequest: 500m
              cpuLimit: 1 
            probes:
              liveness:
                initialDelaySeconds: 15
                path: /actuator/health/liveness
                failureThreshold: 3
                successThreshold: 1
                timeoutSeconds: 3
                periodSeconds: 5
              readiness:
                initialDelaySeconds: 15
                path: /actuator/health/readiness
                failureThreshold: 3
                successThreshold: 1
                timeoutSeconds: 3
                periodSeconds: 5
            ports:
              http:
                name: http
                value: 8080
              management:
                name: management
                value: 8081
            envs:
              - name: greeting.message
                value: <path:kv-v2/data/demo#message>
            log:
              level:
                spring: "info"
                service: "info"
  syncPolicy: {}
```
You can see placeholders with pattern <path:kv-v2/data/demo#message> where Vault Plugin will inject the actual value from Vault secret.

Let’s install this Argo Application and sync them.
```text
# make sure you are in namespace where Argo has benn installed
kubens toolbox

# once you download soruce from GIT repo
kubectl apply -f infra/argocd/argocd-application-with-vault-secrets.yaml

# List ArgoCD applications
argocd app list

# Sync application
argocd app sync toolbox/springboot-argocd-demo
```
Open argocd and verify application is up and running
```text
# argocd url
https://localhost:8080/applications/toolbox/springboot-argocd-demo

# use port other than 8080 as the tunnel to Argo already uses this port
kubectl port-forward -n toolbox svc/springboot-argocd-demo 8090:8080
```
One of the greatest things about the plugin is that if the value changes in Vault, ArgoCD will notice these changes and display `OutOfSync` status. Let's prove it.
```text
# update secrets in Vault
vault kv put kv-v2/demo message="finally aussies won the match. Mad Max rocked" user="secret_user_new" password="secret_password_new"
vault kv put kv-v2/rds_service host="postgres" name="postgres" username="admin" password="admin"

# refresh application as well with target manifests cache
argocd app get toolbox/springboot-argocd-demo --hard-refresh
```
After Hard refresh you should see that your Argo Application back to status OutOfSync what is expected during Vault secret update. Thanks to this mechanism, you don't have to worry about losing control of keeping your secrets up to date.

## Reference
1. https://external-secrets.io/latest/introduction/overview/#running-multiple-controller
2. https://github.com/digitalocean/Kubernetes-Starter-Kit-Developers/blob/main/06-kubernetes-secrets/external-secrets-operator.md
3. https://faun.pub/vault-integration-with-kubernetes-using-external-secrets-operator-7e13a78db406
4. https://verifa.io/blog/comparing-methods-for-accessing-secrets-in-vault-from-kubernetes/index.html
5. https://argocd-vault-plugin.readthedocs.io/en/stable/backends/
## useful commands
```text
minikube start
minikube unpause 
minikube dashboard 

docker build --tag=innotigers/springboot-eso:latest --rm=true .

minikube image load innotigers/springboot-eso:latest
minikube image rm image innotigers/springboot-eso:latest
minikube image ls

minikube image rm image <imagename>:<version>  
minikube image load <imagename>:<version> --daemon

kubectl get secrets/demo-secret -o yaml
```
