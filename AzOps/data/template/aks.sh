#!/bin/bash

if [ -z "$AKS_CLUSTER_NAME" ]; then
    echo "must provide AKS_CLUSTER_NAME env var"
    exit 1;
fi

if [ -z "$AKS_CLUSTER_RESOURCE_GROUP_NAME" ]; then
    echo "must provide AKS_CLUSTER_RESOURCE_GROUP_NAME env var"
    exit 1;
fi

#download kubctl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"

#move kubectl  to local path
mkdir -p ~/.local/bin/kubectl
mv ./kubectl ~/.local/bin/kubectl
chmod +x ~/.local/bin/kubectl/kubectl
PATH=$PATH:~/.local/bin/kubectl

#get AKS credentials
az aks get-credentials --name $AKS_CLUSTER_NAME --resource-group $AKS_CLUSTER_RESOURCE_GROUP_NAME --admin

#cat /root/.kube/config;

echo \"Running Command: $1\"
result=$($1)
echo $result>$AZ_SCRIPTS_OUTPUT_PATH
