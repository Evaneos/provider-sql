#!/usr/bin/env bash
set -e

# setting up colors
BLU='\033[0;34m'
YLW='\033[0;33m'
GRN='\033[0;32m'
RED='\033[0;31m'
NOC='\033[0m' # No Color
echo_info() {
    printf "\n${BLU}%s${NOC}" "$1"
}
echo_step() {
    printf "\n${BLU}>>>>>>> %s${NOC}\n" "$1"
}
echo_sub_step() {
    printf "\n${BLU}>>> %s${NOC}\n" "$1"
}

echo_step_completed() {
    printf "${GRN} [✔]${NOC}"
}

echo_success() {
    printf "\n${GRN}%s${NOC}\n" "$1"
}
echo_warn() {
    printf "\n${YLW}%s${NOC}" "$1"
}
echo_error() {
    printf "\n${RED}%s${NOC}" "$1"
    exit 1
}

# ------------------------------
projectdir="$( cd "$( dirname "${BASH_SOURCE[0]}")"/../.. && pwd )"

# get the build environment variables from the special build.vars target in the main makefile
eval $(make --no-print-directory -C ${projectdir} build.vars)

# ------------------------------

# Provide safe defaults for variables that may not be set by build.vars
: "${KIND_VERSION:=unknown}"
: "${KIND_NODE_IMAGE_TAG:=v1.23.4}"

SAFEHOSTARCH="${SAFEHOSTARCH:-amd64}"
CONTROLLER_IMAGE="${BUILD_REGISTRY}/${PROJECT_NAME}-${SAFEHOSTARCH}"

version_tag="$(cat ${projectdir}/_output/version)"
# tag as latest version to load into kind cluster
K8S_CLUSTER="${K8S_CLUSTER:-${BUILD_REGISTRY}-inttests}"

# Optional: set USE_OCI=true to use an in-cluster OCI registry for provider package delivery
# Modes:
#  - USE_OCI=true  => Push .xpkg into an in-cluster registry and install Provider from OCI (no host cache, no PVC)
#  - USE_OCI=false => Extract .xpkg to .gz on host and mount as cache for Crossplane (offline local cache)
USE_OCI=${USE_OCI:-true}


PACKAGE_NAME="provider-sql"
MARIADB_ROOT_PW=$(openssl rand -base64 32)
MARIADB_TEST_PW=$(openssl rand -base64 32)

# cleanup on exit
if [ "$skipcleanup" != true ]; then
  function cleanup {
    echo_step "Cleaning up..."
    export KUBECONFIG=
    # stop port-forward if running
    if [ -f "${projectdir}/.work/registry-pf.pid" ]; then
      pfpid=$(cat "${projectdir}/.work/registry-pf.pid" || true)
      if [ -n "$pfpid" ]; then kill "$pfpid" 2>/dev/null || true; fi
      rm -f "${projectdir}/.work/registry-pf.pid"
    fi
    cleanup_cluster
  }

  trap cleanup EXIT
fi

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
# shellcheck source="$SCRIPT_DIR/postgresdb_functions.sh"
source "$SCRIPT_DIR/postgresdb_functions.sh"
if [ $? -ne 0 ]; then
  echo "postgresdb_functions.sh failed. Exiting."
  exit 1
fi

integration_tests_end() {
  echo_step "--- CLEAN-UP ---"
  cleanup_provider
  echo_success " All integration tests succeeded!"
}

setup_cluster() {
  if [ "${USE_OCI}" = true ]; then
    echo_sub_step "Mode: OCI (no host cache, no PVC)"
  else
    echo_sub_step "Mode: Local cache (.gz mounted via PV/PVC)"
  fi
  local cache_path="${projectdir}/.work/inttest-package-cache"
  local node_image="kindest/node:${KIND_NODE_IMAGE_TAG}"

  if [ "${USE_OCI}" = true ]; then
    echo_step "creating k8s cluster (no cache mount) using kind ${KIND_VERSION} and ${node_image}"
    local config="$( cat <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
EOF
    )"
    echo "${config}" | "${KIND}" create cluster --name="${K8S_CLUSTER}" --wait=5m --image="${node_image}" --config=-
  else
    echo_step "setting up local package cache (.xpkg -> .gz)"
    mkdir -p "${cache_path}"
    echo "created cache dir at ${cache_path}"
    "${UP}" alpha xpkg xp-extract --from-xpkg "${OUTPUT_DIR}"/xpkg/linux_"${SAFEHOSTARCH}"/"${PACKAGE_NAME}"-"${VERSION}".xpkg -o "${cache_path}/${PACKAGE_NAME}-${VERSION}.gz"
    chmod 644 "${cache_path}/${PACKAGE_NAME}-${VERSION}.gz"

    echo_step "creating k8s cluster (with cache mount) using kind ${KIND_VERSION} and ${node_image}"
    local config="$( cat <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraMounts:
  - hostPath: "${cache_path}/"
    containerPath: /cache
EOF
    )"
    echo "${config}" | "${KIND}" create cluster --name="${K8S_CLUSTER}" --wait=5m --image="${node_image}" --config=-
  fi

  echo_step "load controller runtime image into kind cluster"
  "${KIND}" load docker-image "${CONTROLLER_IMAGE}" --name="${K8S_CLUSTER}"

  echo_step "create crossplane-system namespace"

  "${KUBECTL}" create ns crossplane-system

  if [ "${USE_OCI}" != true ]; then
    echo_step "create persistent volume for mounting package-cache"

    local pv_yaml="$( cat <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: package-cache
  labels:
    type: local
spec:
  storageClassName: manual
  capacity:
    storage: 5Mi
  accessModes:
    - ReadWriteOnce
  hostPath:
    path: "/cache"
EOF
    )"

    echo "${pv_yaml}" | "${KUBECTL}" create -f -

    echo_step "create persistent volume claim for mounting package-cache"

    local pvc_yaml="$( cat <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: package-cache
  namespace: crossplane-system
spec:
  accessModes:
    - ReadWriteOnce
  volumeName: package-cache
  storageClassName: manual
  resources:
    requests:
      storage: 1Mi
EOF
    )"

    echo "${pvc_yaml}" | "${KUBECTL}" create -f -
  fi
}

cleanup_cluster() {
  "${KIND}" delete cluster --name="${K8S_CLUSTER}"
}

setup_crossplane() {
  echo_step "installing crossplane from stable channel"

  "${HELM}" repo add crossplane-stable https://charts.crossplane.io/stable/ --force-update
  local chart_version="$("${HELM}" search repo crossplane-stable/crossplane | awk 'FNR == 2 {print $2}')"
  echo_info "using crossplane version ${chart_version}"
  echo
  if [ "${USE_OCI}" = true ]; then
    echo_sub_step "Crossplane cache: emptyDir (OCI mode)"
    "${HELM}" install crossplane --namespace crossplane-system crossplane-stable/crossplane --version ${chart_version} --wait
  else
    echo_sub_step "Crossplane cache: PVC 'package-cache' (local .gz mode)"
    "${HELM}" install crossplane --namespace crossplane-system crossplane-stable/crossplane --version ${chart_version} --wait --set packageCache.pvc=package-cache
  fi
}

setup_local_registry() {
  [ "${USE_OCI}" = true ] || return 0
  echo_step "deploy in-cluster OCI registry"
  local reg_yaml="$( cat <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: registry
  namespace: crossplane-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: registry
  template:
    metadata:
      labels:
        app: registry
    spec:
      containers:
        - name: registry
          image: registry:3.0.0
          ports:
            - containerPort: 5000
          env:
            - name: REGISTRY_STORAGE_DELETE_ENABLED
              value: "true"
---
apiVersion: v1
kind: Service
metadata:
  name: registry
  namespace: crossplane-system
spec:
  selector:
    app: registry
  ports:
    - name: http
      protocol: TCP
      port: 5000
      targetPort: 5000
EOF
  )"
  echo "${reg_yaml}" | "${KUBECTL}" apply -f -
  "${KUBECTL}" -n crossplane-system rollout status deploy/registry --timeout=120s

  echo_step "port-forward registry for pushing xpkg"
  mkdir -p "${projectdir}/.work"
  ( kubectl -n crossplane-system port-forward svc/registry 5000:5000 >/dev/null 2>&1 & echo $! >"${projectdir}/.work/registry-pf.pid" )
  for i in {1..20}; do nc -z localhost 5000 && break || sleep 0.5; done
}

push_xpkg_to_registry() {
  [ "${USE_OCI}" = true ] || return 0
  echo_step "push xpkg to in-cluster registry"
  local xpkg_path="${OUTPUT_DIR}/xpkg/linux_${SAFEHOSTARCH}/${PACKAGE_NAME}-${VERSION}.xpkg"
  local ref_ver="localhost:5000/${PACKAGE_NAME}:${version_tag}"
  local ref_latest="localhost:5000/${PACKAGE_NAME}:latest"
  "${UP}" xpkg push ${ref_ver} -f "${xpkg_path}"
  "${UP}" xpkg push ${ref_latest} -f "${xpkg_path}"
  echo_info "pushed tags: ${ref_ver}, ${ref_latest}"
}

setup_provider() {
  echo_step "installing provider"

  if [ "${USE_OCI}" = true ]; then
    echo_sub_step "Provider package from OCI: registry.crossplane-system.svc.cluster.local:5000/${PACKAGE_NAME}:latest"
    local yaml="$( cat <<EOF
apiVersion: pkg.crossplane.io/v1beta1
kind: DeploymentRuntimeConfig
metadata:
  name: debug-config
spec:
  deploymentTemplate:
    spec:
      selector: {}
      template:
        spec:
          containers:
            - name: package-runtime
              image: "${CONTROLLER_IMAGE}"
              args:
                - --debug
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: "${PACKAGE_NAME}"
spec:
  runtimeConfigRef:
    name: debug-config
  package: "registry.crossplane-system.svc.cluster.local:5000/${PACKAGE_NAME}:latest"
  packagePullPolicy: IfNotPresent
EOF
    )"
    echo "${yaml}" | "${KUBECTL}" apply -f -
  else
    echo_sub_step "Provider package from local cache: ${PACKAGE_NAME}-${VERSION}.gz"
    local yaml="$( cat <<EOF
apiVersion: pkg.crossplane.io/v1beta1
kind: DeploymentRuntimeConfig
metadata:
  name: debug-config
spec:
  deploymentTemplate:
    spec:
      selector: {}
      template:
        spec:
          containers:
            - name: package-runtime
              image: "${CONTROLLER_IMAGE}"
              args:
                - --debug
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: "${PACKAGE_NAME}"
spec:
  runtimeConfigRef:
    name: debug-config
  package: "${PACKAGE_NAME}-${VERSION}.gz"
  packagePullPolicy: Never
EOF
    )"
    echo "${yaml}" | "${KUBECTL}" apply -f -
  fi

  if [ "${USE_OCI}" != true ]; then
    # printing the cache dir contents can be useful for troubleshooting local cache failures
    echo_step "check kind node cache dir contents"
    docker exec "${K8S_CLUSTER}-control-plane" ls -la /cache
  fi

  echo_step "waiting for provider to be installed"
  "${KUBECTL}" wait "provider.pkg.crossplane.io/${PACKAGE_NAME}" --for=condition=healthy --timeout=180s
}

cleanup_provider() {
  echo_step "uninstalling provider"

  "${KUBECTL}" delete provider.pkg.crossplane.io "${PACKAGE_NAME}"
  "${KUBECTL}" delete deploymentruntimeconfig.pkg.crossplane.io debug-config

  echo_step "waiting for provider pods to be deleted"
  timeout=60
  current=0
  step=3
  while [[ $(kubectl get providerrevision.pkg.crossplane.io -o name | wc -l | tr -d '[:space:]') != "0" ]]; do
    echo "waiting another $step seconds"
    current=$((current + step))
    if [[ $current -ge $timeout ]]; then
      echo_error "timeout of ${timeout}s has been reached"
    fi
    sleep $step;
  done
}

setup_tls_certs() {
  echo_step "generating CA key and certificate"
  openssl genrsa -out ca-key.pem 2048
  openssl req -new -x509 -key ca-key.pem -out ca-cert.pem -days 365 -subj "/CN=CA"

  echo_step "generating server key and certificate"
  openssl genrsa -out server-key.pem 2048
  openssl req -new -key server-key.pem -out server-req.pem -subj "/CN=mariadb.default.svc.cluster.local"
  openssl x509 -req -in server-req.pem -CA ca-cert.pem -CAkey ca-key.pem -CAcreateserial -out server-cert.pem -days 365

  echo_step "generating client key and certificate"
  openssl genrsa -out client-key.pem 2048
  openssl req -new -key client-key.pem -out client-req.pem -subj "/CN=client"
  openssl x509 -req -in client-req.pem -CA ca-cert.pem -CAkey ca-key.pem -CAcreateserial -out client-cert.pem -days 365

  echo_step "creating secret for the TLS certificates and keys"
  "${KUBECTL}" create secret generic mariadb-server-tls \
      --from-file=ca-cert.pem \
      --from-file=server-cert.pem \
      --from-file=server-key.pem

  echo_step "creating secret for the client TLS certificates and keys"
  "${KUBECTL}" create secret generic mariadb-client-tls \
      --from-file=ca-cert.pem \
      --from-file=client-cert.pem \
      --from-file=client-key.pem
}

cleanup_tls_certs() {
  echo_step "cleaning up TLS certificate files and secrets"
  for file in *.pem *.srl; do
      rm -f "$file"
  done
  "${KUBECTL}" delete secret mariadb-server-tls
  "${KUBECTL}" delete secret mariadb-client-tls
}

setup_provider_config_no_tls() {
  echo_step "creating ProviderConfig with no TLS"
  local yaml="$( cat <<EOF
apiVersion: mysql.sql.crossplane.io/v1alpha1
kind: ProviderConfig
metadata:
  name: default
spec:
  credentials:
    source: MySQLConnectionSecret
    connectionSecretRef:
      namespace: default
      name: mariadb-creds
EOF
  )"

  echo "${yaml}" | "${KUBECTL}" apply -f -
}

setup_provider_config_tls() {
  echo_step "creating ProviderConfig with TLS"
  local yaml="$( cat <<EOF
apiVersion: mysql.sql.crossplane.io/v1alpha1
kind: ProviderConfig
metadata:
  name: default
spec:
  credentials:
    source: MySQLConnectionSecret
    connectionSecretRef:
      namespace: default
      name: mariadb-creds
  tls: custom
  tlsConfig:
    caCert:
      secretRef:
        namespace: default
        name: mariadb-creds
        key: ca-cert.pem
    clientCert:
      secretRef:
        namespace: default
        name: mariadb-creds
        key: client-cert.pem
    clientKey:
      secretRef:
        namespace: default
        name: mariadb-creds
        key: client-key.pem
    insecureSkipVerify: true
EOF
  )"

  echo "${yaml}" | "${KUBECTL}" apply -f -
}

cleanup_provider_config() {
  echo_step "cleaning up ProviderConfig"
  "${KUBECTL}" delete providerconfig.mysql.sql.crossplane.io default
}

setup_mariadb_no_tls() {
  echo_step "installing MariaDB with no TLS"
  "${KUBECTL}" create secret generic mariadb-creds \
  --from-literal=username="root" \
  --from-literal=password="${MARIADB_ROOT_PW}" \
  --from-literal=endpoint="mariadb.default.svc.cluster.local" \
  --from-literal=port="3306"

  "${HELM}" repo add bitnami https://charts.bitnami.com/bitnami >/dev/null
  "${HELM}" repo update
  "${HELM}" install mariadb bitnami/mariadb \
      --version 24.0.2 \
      --set auth.rootPassword="${MARIADB_ROOT_PW}" \
      --wait
}

setup_mariadb_tls() {
  echo_step "installing MariaDB with TLS"
  "${KUBECTL}" create secret generic mariadb-creds \
    --from-literal=username="test" \
    --from-literal=password="${MARIADB_TEST_PW}" \
    --from-literal=endpoint="mariadb.default.svc.cluster.local" \
    --from-literal=port="3306" \
    --from-file=ca-cert.pem \
    --from-file=client-cert.pem \
    --from-file=client-key.pem

  local values=$(cat <<EOF
auth:
  rootPassword: ${MARIADB_ROOT_PW}
primary:
  extraFlags: "--ssl --require-secure-transport=ON --ssl-ca=/opt/bitnami/mariadb/certs/ca-cert.pem --ssl-cert=/opt/bitnami/mariadb/certs/server-cert.pem --ssl-key=/opt/bitnami/mariadb/certs/server-key.pem"
  configurationSecret: mariadb-server-tls
  extraVolumes:
    - name: tls-certificates
      secret:
        secretName: mariadb-server-tls
  extraVolumeMounts:
    - name: tls-certificates
      mountPath: /opt/bitnami/mariadb/certs
      readOnly: true
initdbScripts:
  init.sql: |
    CREATE USER 'test'@'%' IDENTIFIED BY '${MARIADB_TEST_PW}' REQUIRE X509;
    GRANT ALL PRIVILEGES ON *.* TO 'test'@'%' WITH GRANT OPTION;
    FLUSH PRIVILEGES;
EOF
  )

  "${HELM}" repo add bitnami https://charts.bitnami.com/bitnami >/dev/null
  "${HELM}" repo update
  "${HELM}" install mariadb bitnami/mariadb \
      --version 24.0.2 \
      --values <(echo "$values") \
      --wait
}

cleanup_mariadb() {
  echo_step "uninstalling MariaDB"
  "${HELM}" uninstall mariadb
  "${KUBECTL}" delete secret mariadb-creds
}

test_create_database() {
  echo_step "test creating MySQL Database resource"
  "${KUBECTL}" apply -f ${projectdir}/examples/mysql/database.yaml

  echo_info "check if is ready"
  "${KUBECTL}" wait --timeout 2m --for condition=Ready -f ${projectdir}/examples/mysql/database.yaml
  echo_step_completed
}

test_create_user() {
  echo_step "test creating MySQL User resource"
  local user_pw="asdf1234"
  "${KUBECTL}" create secret generic example-pw --from-literal password="${user_pw}"
  "${KUBECTL}" apply -f ${projectdir}/examples/mysql/user.yaml

  echo_info "check if is ready"
  "${KUBECTL}" wait --timeout 2m --for condition=Ready -f ${projectdir}/examples/mysql/user.yaml
  echo_step_completed

  echo_info "check if connection secret exists"
  local pw=$("${KUBECTL}" get secret example-connection-secret -ojsonpath='{.data.password}' | base64 --decode)
  [ "${pw}" == "${user_pw}" ]
  echo_step_completed
}

test_update_user_password() {
  echo_step "test updating MySQL User password"
  local user_pw="newpassword"
  "${KUBECTL}" create secret generic example-pw --from-literal password="${user_pw}" --dry-run -oyaml | \
    "${KUBECTL}" apply -f -

  # trigger reconcile
  "${KUBECTL}" annotate -f ${projectdir}/examples/mysql/user.yaml reconcile=now

  sleep 3

  echo_info "check if connection secret has been updated"
  local pw=$("${KUBECTL}" get secret example-connection-secret -ojsonpath='{.data.password}' | base64 --decode)
  [ "${pw}" == "${user_pw}" ]
  echo_step_completed
}

test_create_grant() {
  echo_step "test creating MySQL Grant resource"
  "${KUBECTL}" apply -f ${projectdir}/examples/mysql/grant_database.yaml

  echo_info "check if is ready"
  "${KUBECTL}" wait --timeout 2m --for condition=Ready -f ${projectdir}/examples/mysql/grant_database.yaml
  echo_step_completed
}

test_all() {
  test_create_database
  test_create_user
  test_update_user_password
  test_create_grant
}

cleanup_test_resources() {
  echo_step "cleaning up test resources"
  "${KUBECTL}" delete -f ${projectdir}/examples/mysql/grant_database.yaml
  "${KUBECTL}" delete -f ${projectdir}/examples/mysql/database.yaml
  "${KUBECTL}" delete -f ${projectdir}/examples/mysql/user.yaml
  "${KUBECTL}" delete secret example-pw
}

setup_cluster
setup_crossplane
setup_local_registry
push_xpkg_to_registry
setup_provider

echo_step "--- INTEGRATION TESTS - NO TLS ---"

setup_mariadb_no_tls
setup_provider_config_no_tls

test_all

cleanup_test_resources
cleanup_provider_config
cleanup_mariadb

echo_step "--- INTEGRATION TESTS - TLS ---"

setup_tls_certs
setup_mariadb_tls
setup_provider_config_tls

test_all

cleanup_test_resources
cleanup_provider_config
cleanup_mariadb
cleanup_tls_certs

echo_step "--- INTEGRATION TESTS FOR MySQL ACCOMPLISHED SUCCESSFULLY ---"

echo_step "--- TESTING POSTGRESDB ---"
integration_tests_postgres
echo_step "--- INTEGRATION TESTS FOR POSTGRESDB ACCOMPLISHED SUCCESSFULLY ---"

integration_tests_end