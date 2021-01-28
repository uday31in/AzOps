
#!/bin/bash
#set -e

# if [ -z "$AKS_CLUSTER_NAME" ]; then
#     echo "must provide AKS_CLUSTER_NAME env var"
#     exit 1;
# fi

# if [ -z "$AKS_CLUSTER_RESOURCE_GROUP_NAME" ]; then
#     echo "must provide AKS_CLUSTER_RESOURCE_GROUP_NAME env var"
#     exit 1;
# fi

function configureKubectl()
{
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
}

function installHelm()
{
   curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash
}


main() {

    if ! command -v kubectl &> /dev/null
    then
        configureKubectl
    fi

    if ! command -v kubectl &> /dev/null
    then
        installHelm
    fi

    echo "calling main with $@"
    IFS=';' read -r -a command <<< "$@"
    echo "Number of commands: ${#command[@]}"
    output='{"results": []}'
    for (( i=0; i<${#command[@]}; i++ ));
    do
        cmd=${command[$i]}
        echo "Executing command: ${command[$i]}"
        read -r -d '' result <<< $(${command[$i]})
        echo "$result"
        if [ ! -z "$result" ]; then
            if jq -e . >/dev/null 2>&1 <<<"$result"; then
                echo "Parsed JSON successfully"
                output=$(echo $output | jq    --arg i "${command[$i]}" \
                                            --argjson r "$result" \
                                            '.results += [{command: $i, result: $r}]')
            else
                echo "Failed to parse JSON, or got false/null"
                output=$(echo $output | jq  --arg i "${command[$i]}" \
                                            --arg r "$result" \
                                        '.results += [{command: $i, result: $r}]')
            fi
        else
            echo "result is null"
            output=$(echo $output | jq  --arg i "${command[$i]}" \
                                        '.results += [{command: $i}]')
        fi
    done
    echo "-------------"
    echo "AZ_SCRIPTS_OUTPUT_PATH: $AZ_SCRIPTS_OUTPUT_PATH"
    echo $output
    $output > $AZ_SCRIPTS_OUTPUT_PATH
    #cat $AZ_SCRIPTS_OUTPUT_PATH
}
main "$@"