#!/bin/bash

export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)

echo "Registering features and providers..."
az provider register -n Microsoft.Monitor
az provider register -n Microsoft.ContainerService
az provider register -n Microsoft.Dashboard
az provider register -n Microsoft.AlertsManagement
az feature register --namespace Microsoft.ContainerService --name AutomaticSKUPreview

# wait for feature registration
while [[ $(az feature show --namespace "Microsoft.ContainerService" --name "AutomaticSKUPreview" --query "properties.state" -o tsv) != "Registered" ]]; do
  echo "Waiting for AutomaticSKUPreview feature registration..."
  sleep 3
done

# propagate the feature registrations
az provider register -n Microsoft.ContainerService

while [[ $(az provider show --namespace "Microsoft.Dashboard" --query "registrationState" -o tsv) != "Registered" ]]; do
  echo "Waiting for Microsoft.Dashboard provider registration..."
  sleep 3
done

while [[ $(az provider show --namespace "Microsoft.AlertsManagement" --query "registrationState" -o tsv) != "Registered" ]]; do
  echo "Waiting for Microsoft.AlertsManagement provider registration..."
  sleep 3
done

echo "Installing extensions..."
az extension add --name aks-preview
az extension add --name amg

echo "Applying Terraform and exporting output variables..."
cd src/infra/terraform
terraform init
terraform apply -var="owner=$(whoami)" --auto-approve

# check return code from previous command
if [ $? -ne 0 ]; then
  echo "Terraform apply failed. Exiting..."
  exit 1
fi

export RG_NAME=$(terraform output -raw rg_name)
export AKS_NAME=$(terraform output -raw aks_name)
export OAI_GPT_ENDPOINT=$(terraform output -raw oai_gpt_endpoint)
export OAI_GPT_DEPLOYMENT_NAME=$(terraform output -raw oai_gpt_model_name)
export OAI_DALLE_ENDPOINT=$(terraform output -raw oai_dalle_endpoint)
export OAI_DALLE_DEPLOYMENT_NAME=$(terraform output -raw oai_dalle_model_name)
export OAI_DALLE_API_VERSION=$(terraform output -raw oai_dalle_api_version)
export OAI_IDENTITY_CLIENT_ID=$(terraform output -raw oai_identity_client_id)
export AMG_NAME=$(terraform output -raw amg_name)
export DB_CONTAINER_NAME=$(terraform output -raw db_container_name)
export DB_DATABASE_NAME=$(terraform output -raw db_database_name)
export DB_ENDPOINT=$(terraform output -raw db_endpoint)
export DB_IDENTITY_CLIENT_ID=$(terraform output -raw db_identity_client_id)
export SB_HOSTNAME=$(terraform output -raw sb_hostname)
export SB_QUEUE_NAME=$(terraform output -raw sb_queue_name)
export SB_IDENTITY_CLIENT_ID=$(terraform output -raw sb_identity_client_id)

echo "Downloading kubeconfig..."
az aks get-credentials --name $AKS_NAME --resource-group $RG_NAME

which kubelogin
if [ $? -ne 0 ]; then
  echo "Installing kubelogin..."
  sudo az aks install-cli
fi

echo "Deploying a sample app to kickstart the user nodepool nodes..."
kubectl apply -f https://raw.githubusercontent.com/microsoft/aitour-cloud-native-apps-with-azure-ai-and-aks/refs/heads/main/src/manifests/sample.yaml

echo "Deploying prometheus scrape configs..."
kubectl create configmap -n kube-system ama-metrics-prometheus-config --from-file prometheus-config

echo "Installing the gateway api..."
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml

echo "Deploying internal and external gateways..."
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: gateway-internal
  namespace: aks-istio-ingress
spec:
  gatewayClassName: istio
  addresses:
  - value: aks-istio-ingressgateway-internal.aks-istio-ingress.svc.cluster.local
    type: Hostname
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: All
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: gateway-external
  namespace: aks-istio-ingress
spec:
  gatewayClassName: istio
  addresses:
  - value: aks-istio-ingressgateway-external.aks-istio-ingress.svc.cluster.local
    type: Hostname
  listeners:
  - name: default
    hostname: "*.aks.rocks"
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: All
EOF

echo "Installing ArgoCD and Argo Rollouts..."
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm upgrade argocd argo/argo-cd --install --namespace argocd --create-namespace --version 7.7.15 --set 'global.podAnnotations.karpenter\.sh/do-not-disrupt=true'

# Function to check the status of argocd installation
check_argocd_status() {
  helm list -n argocd -ojson | jq -r '.[] | select(.name=="argocd") | .status'
}

# Initial status check
status=$(check_argocd_status)

# Loop until the status is not "failed"
while [ "$status" == "failed" ]; do
  echo "ArgoCD installation failed. Retrying..."
  helm upgrade argocd argo/argo-cd --install --namespace argocd --create-namespace --version 7.7.15 --set 'global.podAnnotations.karpenter\.sh/do-not-disrupt=true'
  sleep 5  # Optional: wait for a few seconds before checking again
  status=$(check_argocd_status)
done

helm upgrade argo-rollouts argo/argo-rollouts --install --namespace argo-rollouts --create-namespace --version 2.38.2 --set 'controller.podAnnotations.karpenter\.sh/do-not-disrupt=true' --set 'dashboard.podAnnotations.karpenter\.sh/do-not-disrupt=true'

# Function to check the status of argo-rollouts
check_argorollouts_status() {
  helm list -n argo-rollouts  -ojson | jq -r '.[] | select(.name=="argo-rollouts ") | .status'
}

# Initial status check
status=$(check_argorollouts_status)

# Loop until the status is not "failed"
while [ "$status" == "failed" ]; do
  echo "ArgoCD installation failed. Retrying..."
  helm upgrade argo-rollouts argo/argo-rollouts --install --namespace argo-rollouts --create-namespace --version 2.38.2 --set 'controller.podAnnotations.karpenter\.sh/do-not-disrupt=true' --set 'dashboard.podAnnotations.karpenter\.sh/do-not-disrupt=true'
  sleep 5  # Optional: wait for a few seconds before checking again
  status=$(check_argorollouts_status)
done

echo "Install the traffic router plugin for gateway api..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: argo-rollouts-config
  namespace: argo-rollouts
data:
  trafficRouterPlugins: |-
    - name: "argoproj-labs/gatewayAPI"
      location: "https://github.com/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi/releases/download/v0.4.1/gatewayapi-plugin-linux-amd64"
EOF
kubectl rollout restart deployment -n argo-rollouts argo-rollouts

echo "Creating the gateway controller role and binding..."
kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: gateway-controller-role
  namespace: argo-rollouts
rules:
  - apiGroups:
      - "*"
    resources:
      - "*"
    verbs:
      - "*"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: gateway-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: gateway-controller-role
subjects:
  - namespace: argo-rollouts
    kind: ServiceAccount
    name: argorollouts-release-argo-rollouts
EOF

echo "Creating the demo namespace and setting the istio revision label..."
kubectl create namespace pets
kubectl label namespace pets istio.io/rev=asm-1-22

echo "Create the service account and config map for the ai service..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    azure.workload.identity/client-id: $OAI_IDENTITY_CLIENT_ID
  name: ai-service-account
  namespace: pets
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: ai-service-configs
  namespace: pets
data:
  USE_AZURE_OPENAI: "True"  
  USE_AZURE_AD: "True"
  AZURE_OPENAI_ENDPOINT: $OAI_GPT_ENDPOINT
  AZURE_OPENAI_DEPLOYMENT_NAME: $OAI_GPT_DEPLOYMENT_NAME
  AZURE_OPENAI_DALLE_ENDPOINT: $OAI_DALLE_ENDPOINT
  AZURE_OPENAI_DALLE_DEPLOYMENT_NAME: $OAI_DALLE_DEPLOYMENT_NAME
  AZURE_OPENAI_API_VERSION: $OAI_DALLE_API_VERSION
EOF

echo "Creating the service account and config map for makeline-service..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    azure.workload.identity/client-id: $DB_IDENTITY_CLIENT_ID
  name: makeline-service-account
  namespace: pets
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: makeline-service-configs
  namespace: pets
data:  
  USE_WORKLOAD_IDENTITY_AUTH: "true"
  ORDER_QUEUE_HOSTNAME: $SB_HOSTNAME
  ORDER_QUEUE_NAME: $SB_QUEUE_NAME
  ORDER_DB_URI: $DB_ENDPOINT
  ORDER_DB_NAME: $DB_DATABASE_NAME
  ORDER_DB_API: "cosmosdbsql"
  ORDER_DB_CONTAINER_NAME: $DB_CONTAINER_NAME
  ORDER_DB_PARTITION_KEY: "storeId"
  ORDER_DB_PARTITION_VALUE: "pets"
EOF

echo "Creating the service account and config map for order-service..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    azure.workload.identity/client-id: $SB_IDENTITY_CLIENT_ID
  name: order-service-account
  namespace: pets
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: order-service-configs
  namespace: pets
data:
  USE_WORKLOAD_IDENTITY_AUTH: "true"
  ORDER_QUEUE_HOSTNAME: $SB_HOSTNAME
  ORDER_QUEUE_NAME: $SB_QUEUE_NAME
  FASTIFY_ADDRESS: "0.0.0.0"
EOF

echo "Forking the demo repository..."
gh auth login -h github.com -s delete_repo
gh repo fork microsoft/aitour-cloud-native-apps-with-azure-ai-and-aks --fork-name ai-tour-aks-demo --clone
cd ai-tour-aks-demo
gh repo set-default

echo "Setting up the ArgoCD app repo..."
kubectl config set-context --current --namespace=argocd
argocd login --core
argocd repo add $(gh repo view --json url | jq .url -r) --username $(gh api user --jq .login) --password $(gh auth token)

echo "Demo setup complete! Now you can run the 'make run' command to start the demo."
cd -
