#!/usr/bin/env bash

set -ex

BITOPS_DIR="/opt/bitops"
SCRIPTS_DIR="$BITOPS_DIR/scripts"

# ops repo paths
ROOT_DIR="/opt/bitops_deployment"
ENVROOT="$ROOT_DIR/$ENVIRONMENT"

export PATH=/root/.local/bin:$PATH
export TEMPDIR="/tmp/bitops_deployment"
export IMG_REPO=""
export KUBE_CONFIG_FILE="/tmp/bitops_deployment/.kube/config"

if [ -e /opt/bitops_deployment ];
then
    echo "Creating temp directory: $TEMPDIR"
    if ! mkdir -p /tmp/bitops_deployment/.kube
    then 
        printf "${ERROR}failed to create: $TEMPDIR"
    else 
        echo "Successfully created $TEMPDIR "
    fi

    if ! cp -rf /opt/bitops_deployment/* /tmp/bitops_deployment/
    then 
        printf "${ERROR}failed to copy repo to: $TEMPDIR"
    else 
        echo "Successfully Copied repo to $TEMPDIR "
    fi
fi

echo "Installing charts..."

if [ -z "$AWS_ACCESS_KEY_ID" ]; then
  printf "${ERROR}environment variable (AWS_ACCESS_KEY_ID) not set"
  exit 1
fi
if [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
  printf "${ERROR}environment variable (AWS_SECRET_ACCESS_KEY) not set"
  exit 1
fi
if [ -z "$AWS_DEFAULT_REGION" ]; then
  printf "${ERROR}environment variable (AWS_DEFAULT_REGION) not set"
  exit 1
fi
if [ -z "$ENVIRONMENT" ]; then
  printf "${ERROR}environment variable (ENVIRONMENT) not set"
  exit 1
fi
if [ -n "$DEBUG" ]; then
  echo "environment variable (DEBUG) set"
  export HELM_DEBUG_COMMAND="--debug"
  echo "DEBUG ARGS: $HELM_DEBUG_COMMAND"
fi
if [ -n "$HELM_SECRETS_FILE_BASE64" ]; then
    echo "$HELM_SECRETS_FILE_BASE64" | base64 -d > $TEMPDIR/default/values-secrets.yaml
fi
if [ -z "$NAMESPACE" ]; then
  printf "${ERROR}environment variable (NAMESPACE) not set"
  exit 1
fi
if [ -z "$KUBECONFIG_BASE64" ]; then
  printf "${ERROR}environment variable (KUBECONFIG_BASE64) not set"
  exit 1
else
  if [ -e "$TEMPDIR"/.kube/config ]; then
      echo "Found kube config."
  else
      echo "Can not find kubeconfig. Creating..."
      echo $KUBECONFIG_BASE64 | base64 -d > "$TEMPDIR"/.kube/config
  fi
fi

path=""

if [ -z "$HELM_CHARTS_DIRECTORY" ]
then 
    echo "Helm directory not set. Using default directory."
    path=$ENVROOT/helm
else
    echo "Using provided Helm directory: $HELM_CHARTS_DIRECTORY"
    cp -rf "$HELM_CHARTS_DIRECTORY $ENVROOT/"
    path="$ENVROOT/$HELM_CHARTS_DIRECTORY/$ENVIRONMENT/helm"
fi

#Check if nodes are available

kubectl get nodes --kubeconfig=$KUBE_CONFIG_FILE

cd $path
for subDir in `ls`
do

    # Check for Before Deploy Scripts
    bash -x $SCRIPTS_DIR/deploy/before-deploy.sh $path/$subDir
    
    # Check if we should copy CRDs
    if [ -n "$COPY_DEFAULT_CRDS" ]; then 
        if [ -d "$COPY_DEFAULT_CRDS/$subDir/crd"]; then
            echo "Copying CRDs"
        fi
    fi

    # Initialize values files

    VALUES_FILE_PATH="./$subDir/values.yaml"
    VALUES_SECRETS_FILE_PATH="./$subDir/values-secrets.yaml"
    VALUES_VERSIONS_FILE_PATH="./$subDir/values-versions.yaml"
    DEFAULT_VALUES_FILE_PATH="$ENVROOT/default/helm/$subDir/values.yaml"
    ADDITIONAL_VALUES_FILES_PATH="$ENVROOT/default/helm/$subDir/values-files"
    DEFAULT_CHART_ROOT="$ENVROOT/default/helm/$subDir"
    CHART_ROOT="$TMPDIR/$ENVIRONMENT/helm/$subDir"
    echo "Updating dependencies in "$(pwd)"/"$subDir" ..."
    rm -rf "$subDir/charts"
    helm dep up "$(pwd)"/"$subDir"

    # Initialize values command.

    MAIN_VALUES_FILES_COMMAND=""
    for values_file in $VALUES_FILE_PATH $VALUES_SECRETS_FILE_PATH $VALUES_VERSIONS_FILE_PATH $DEFAULT_VALUES_FILE_PATH
    do
        if [ -e "$values_file" ] && [[ -s "$values_file" ]];
        then
            MAIN_VALUES_FILES_COMMAND="$MAIN_VALUES_FILES_COMMAND -f $values_file "
        else
            echo "echo values file not found."
        fi
    done

    VALUES_FILES_COMMAND=""
    if [ -d "$ADDITIONAL_VALUES_FILES_PATH" ]; then
        echo "Additional values directory exists."
        for values_file in `ls "$ADDITIONAL_VALUES_FILES_PATH"`
        do
            echo "processing values-file: $values_file"
            VALUES_FILES_COMMAND="$VALUES_FILES_COMMAND -f $ADDITIONAL_VALUES_FILES_PATH/$values_file "
        done
    else 
        echo "No values file directory. Skipping..."
    fi

    # Copy default CRDs.

    if [ "$(shyaml get-value copy_defaults.crds < ./$subDir/bitops-config.yaml)" == 'True' ]; then
        echo "COPY_DEFAULT_CRDS set"
        if [ -d $DEFAULT_CHART_ROOT/$subDir/crds ]; then
            echo "default crds/ exist"
            # TODO: handle if $CHART_ROOT/crds already exists (merge vs overwrite)?
            cp -rf $DEFAULT_CHART_ROOT/crds/*.yaml ./$subDir/crds/
        else
            printf "${ERROR} crds/ does not exist...${NC}"
        fi
    else
        echo "COPY_DEFAULT_CRDS not set"
    fi

    # Copy default Charts.

    if [ "$(shyaml get-value copy_defaults.charts < ./$subDir/bitops-config.yaml)" == 'True' ]; then
        echo "COPY_DEFAULT_CHARTS set"
        if [ -d $DEFAULT_CHART_ROOT/$subDir/charts ]; then
            echo "default crds/ exist"
            # TODO: handle if $CHART_ROOT/crds already exists (merge vs overwrite)?
            cp -rf $DEFAULT_CHART_ROOT/charts/*.yaml ./$subDir/charts/
        else
            printf "${ERROR} charts/ does not exist...${NC}"
        fi
    else
        echo "COPY_DEFAULT_CHARTS not set"
        printf "${SUCCESS} Helm deployment was successful...${NC}"
    fi

    # Copy default Templates.

    if [ "$(shyaml get-value copy_defaults.templates < ./$subDir/bitops-config.yaml)" == 'True' ]; then
        echo "COPY_DEFAULT_TEMPLATES set"
        if [ -d $DEFAULT_CHART_ROOT/$subDir/templates ]; then
            echo "default crds/ exist"
            # TODO: handle if $CHART_ROOT/crds already exists (merge vs overwrite)?
            cp -rf $DEFAULT_CHART_ROOT/templates/*.yaml ./$subDir/templates/
        else
            printf "${ERROR}  templates/ does not exist...${NC}"
        fi
    else
        echo "COPY_DEFAULT_TEMPLATES not set"
    fi

    # Copy default Schema.

    if [ "$(shyaml get-value copy_defaults.schema < ./$subDir/bitops-config.yaml)" == 'True' ]; then
        echo "COPY_DEFAULT_SCHEMA set"
        if [ -d $DEFAULT_CHART_ROOT/$subDir/schema ]; then
            echo "default crds/ exist"
            # TODO: handle if $CHART_ROOT/crds already exists (merge vs overwrite)?
            cp -rf $DEFAULT_CHART_ROOT/templates/*.yaml ./$subDir/templates/
        else
            printf "${ERROR}  schema/ does not exist...${NC}"
        fi
    else
        echo "COPY_DEFAULT_SCHEMA not set"
    fi

    # Handle versions files.

    VALUES_VERSIONS_FILE_PATH="$CHART_ROOT/values-versions.yaml"
    echo "Checking existence of versions file ($VALUES_VERSIONS_FILE_PATH)"
    VALUES_VERSIONS_FILE_COMMAND=""
    if [ -f "$VALUES_VERSIONS_FILE_PATH" ]; then
        echo "versions file exists.  Including it in deployment."
        VALUES_VERSIONS_FILE_COMMAND="-f $VALUES_VERSIONS_FILE_PATH"
    else
        echo "versions file does not exist. Skipping."
    fi

    # Handle secrets file.

    VALUES_SECRETS_FILE_PATH="$CHART_ROOT/values-secrets.yaml"
    echo "Checking existence of secrets file ($VALUES_SECRETS_FILE_PATH)"
    VALUES_SECRETS_FILE_COMMAND=""
    if [ -f "$VALUES_SECRETS_FILE_PATH" ]; then
        echo "secrets file exists.  Including it in deployment."
        VALUES_SECRETS_FILE_COMMAND="-f $VALUES_SECRETS_FILE_PATH"
    else
        echo "versions file does not exist. Skipping."
    fi

    # Deploy Chart.

    HELM_RELEASE_NAME="$subDir"
    CHART="$subDir"
    NAMESPACE=$(shyaml get-value namespace < $ENVROOT/helm/$subDir/bitops.config.yaml | sed 's/^ //' | sed 's/\s$//')
    echo "Checking NAMESPACE2: $NAMESPACE:"
    TIMEOUT=$(shyaml get-value timeout < $ENVROOT/helm/$subDir/bitops.config.yaml)

    # Check if namespace exists and create it if it doesn't.
    echo "Helm Command: helm upgrade $HELM_RELEASE_NAME ./$CHART --cleanup-on-fail --atomic --install --timeout="$TIMEOUT" $MAIN_VALUES_FILES_COMMAND  $VALUES_FILES_COMMAND"
    if [ -n "$(kubectl get namespaces --kubeconfig=$KUBE_CONFIG_FILE | grep $NAMESPACE)" ];
    then
        echo "The namespace $NAMESPACE exists. Skipping creation..."
    else
        echo "The namespace $NAMESPACE does not exists. Creating..."
        kubectl create namespace $NAMESPACE --kubeconfig=$KUBE_CONFIG_FILE
    fi

    RESULT=""
    helm list --all --all-namespaces --kubeconfig="$KUBE_CONFIG_FILE" > /tmp/check_release.txt

    if [ -n "$(grep "$HELM_RELEASE_NAME" /tmp/check_release.txt)" ];
    then 
        echo "Checking last deployment status"
        helm history $HELM_RELEASE_NAME --namespace $NAMESPACE --kubeconfig="$KUBE_CONFIG_FILE"
        RESULT="$(helm history $HELM_RELEASE_NAME --namespace $NAMESPACE --kubeconfig="$KUBE_CONFIG_FILE" --output yaml | shyaml get-value -1 | shyaml get-value status)"
        echo "Helm deployment status: $RESULT "
    else
        echo "No history"
    fi

    if [ "$RESULT" == "complete" ] || [ "$RESULT" == "deployed" ];
    then
        echo "Upgrading Release: $HELM_RELEASE_NAME"
        helm upgrade $HELM_RELEASE_NAME ./$CHART --install --timeout="$TIMEOUT" \
        --cleanup-on-fail \
        --atomic \
        --kubeconfig="$KUBE_CONFIG_FILE" \
        --namespace="$NAMESPACE" \
        $HELM_DEBUG_COMMAND \
        $MAIN_VALUES_FILES_COMMAND \
        $VALUES_FILES_COMMAND
    else
        if [ -z "$RESULT" ];
        then
            echo 'New installation...'
            helm install $HELM_RELEASE_NAME ./$CHART --kubeconfig="$KUBE_CONFIG_FILE" --namespace="$NAMESPACE" --atomic --timeout="$TIMEOUT" \
            $HELM_DEBUG_COMMAND \
            $MAIN_VALUES_FILES_COMMAND \
            $VALUES_FILES_COMMAND
        else
            echo "The previous instalation failed. Rolling back to last successful release."
            helm rollback $HELM_RELEASE_NAME 0 --namespace $NAMESPACE --kubeconfig="$KUBE_CONFIG_FILE" --cleanup-on-fail $HELM_DEBUG_COMMAND
        fi
    fi

    # Run After Deploy Scripts if any.

    bash -x $SCRIPTS_DIR/deploy/after-deploy.sh $path/$subDir

done
cd $ENVROOT
printf "${SUCCESS} Helm deployment was successful...${NC}"



# TODO: charts/
# TODO: templates/
# TODO: values.schema.json
# TODO: kubefiles/
#  - Additional configuration
#  - Example: Grafana dashboards.