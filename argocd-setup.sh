#!/bin/bash
set -ueo pipefail
 
 
GKE_CLUSTER_NAME="buildbuddy-acc"
REGION="europe-west4"
PROJECT="asml-dta-de-greenhouse-cloud-b"
 
echo "Start ArgoCD installation process..."
 
echo "Authenticate to the GKE cluster"
gcloud container clusters get-credentials $GKE_CLUSTER_NAME --region $REGION --project $PROJECT
 
kubectl get nodes
if [ $? -ne 0 ]; then
    echo "Failed to connect to the GKE cluster."
    exit 1
else
    echo "Connected to the GKE cluster."
fi
 
echo "Setup secrets and TLS..."
# Retrieve secrets from GCP Secret Manager
gcloud secrets versions access latest --secret="acceptance-tls-certificate" > ACCEPTANCE_TLS_CERTIFICATE
gcloud secrets versions access latest --secret="acceptance-tls-private-key" > ACCEPTANCE_TLS_PRIVATE_KEY
gcloud secrets versions access latest --secret="githubapp-private-key-greenhouse-cloud-workloads" > GITHUB_APP_PRIVATE_KEY_GREENHOUSE_CLOUD_WORKLOADS
gcloud secrets versions access latest --secret="asml-ca-04-public-key" > ASML_CA_PUBLIC_KEY
 
# Set up cleanup handler in case of script exit or interruption
cleanup_and_exit() {
    rm -fv ACCEPTANCE_TLS_CERTIFICATE ACCEPTANCE_TLS_PRIVATE_KEY
    rm -fv GITHUB_APP_PRIVATE_KEY_GREENHOUSE_CLOUD_WORKLOADS
    rm -fv ARTIFACTORY_DE_TLS_CERTIFICATE
    rm -fv ASML_CA_PUBLIC_KEY
    unset ARGOCD_INIT_ADMIN_PASSWORD
    exit
}
trap cleanup_and_exit EXIT INT TERM
 
export GKE_CLUSTER_VERSION=$(gcloud container clusters describe $GKE_CLUSTER_NAME --format="value(currentMasterVersion)" --region=$REGION)
 
echo "Add Artifactory-DE's CA public key to the GKE nodes"
gcloud container clusters update $GKE_CLUSTER_NAME --location=$REGION --containerd-config-from-file=./gcloud/containerd-configuration.yml
echo "Update the GKE node pool..."
gcloud container clusters upgrade $GKE_CLUSTER_NAME --location=$REGION --cluster-version=$GKE_CLUSTER_VERSION --node-pool=argocd-node-pool
 
echo "Checking if ArgoCD is deployed on GKE..."
# Check if ArgoCD is deployed on GKE
check_argocd_installed() {
    if kubectl get namespaces | grep -q argocd; then
        return 0
    fi
    if kubectl get pods -A | grep -q argocd-server; then
        return 0
    fi
    return 1
}
 
if check_argocd_installed; then
    echo "ArgoCD is already deployed."
else
    echo "ArgoCD is not deployed. Proceeding with installation..."
 
    # Deploy ArgoCD
    echo "Deploying ArgoCD to the GKE cluster..."
    ARGOCD_VERSION="6.7.12"
    # Crete ArgoCD namespace
    kubectl create ns argocd
    # Create Kubernetes secret for ArgoCD TLS
    kubectl create secret tls argocd-server-tls --cert=ACCEPTANCE_TLS_CERTIFICATE --key=ACCEPTANCE_TLS_PRIVATE_KEY --namespace=argocd
    # Crete ArgoCD backendconfig
    kubectl apply -f ./argocd/backendconfig.yml
    # Deploy ArgoCD
    helm repo add argo https://artifactory-de.asml.com/artifactory/api/helm/argo-helm-virtual
    helm repo update
    helm upgrade --install argocd argo/argo-cd --version=$ARGOCD_VERSION --create-namespace --namespace argocd --values ./argocd/values.yml
 
    # Wait for ArgoCD to become ready
    echo "Waiting for ArgoCD to become ready..."
    sleep 180
 
    # Verify ArgoCD installation
    kubectl get pods -n argocd
    if [ $? -eq 0 ]; then
        echo "ArgoCD installed successfully."
    else
        echo "Failed to install ArgoCD."
        exit 1
    fi
fi
 
echo "Checking ArgoCD CLI version..."
argocd version --client
 
# Get ArgoCD admin password
echo "Retrieving ArgoCD initial Admin password..."
ARGOCD_INIT_ADMIN_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
 
# ArgoCD Login
echo "Login using ArgoCD initial Admin password..."
argocd login argocd.greenhouse-acc.gcp.asml.com --username admin --password $ARGOCD_INIT_ADMIN_PASSWORD --grpc-web
 
echo "Start argoCD configuration process..."
# Add TLS Certificate for Artifactory-DE
argocd cert add-tls --from ASML_CA_PUBLIC_KEY artifactory-de.asml.com
 
# Add a repository
echo "Adding https://gh.asml.com/asml-gh/greenhouse-cloud-workloads.git repository"
argocd repo add https://gh.asml.com/asml-gh/greenhouse-cloud-workloads.git \
     --github-app-id 195 \
     --github-app-installation-id 409 \
     --github-app-private-key-path GITHUB_APP_PRIVATE_KEY_GREENHOUSE_CLOUD_WORKLOADS \
     --github-app-enterprise-base-url https://gh.asml.com/api/v3 \
     --grpc-web
 
# Bootstrap AppsOfApps
echo "Bootstrap AppsOfApps"
argocd app create root-app \
    --repo https://gh.asml.com/asml-gh/greenhouse-cloud-workloads \
    --path GitOps/gcp/apps \
    --revision dev \
    --dest-server https://kubernetes.default.svc \
    --dest-namespace argocd \
    --sync-policy automated \
    --grpc-web
 
echo "Application created and synced."
cleanup_and_exit  # For explicit cleanup