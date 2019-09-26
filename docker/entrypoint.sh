#!/bin/bash
#
# Copyright (C) 2019  Rohith Jayawardene <gambol99@gmail.com>
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

log()      { (2>/dev/null echo -e "$@"); }
info()     { log "[$(date)][info] $@";   }
failed()   { log "[$(date)][fail] $@";   }
error()    { log "[$(date)][error] $@";  }

CONFIG_DIR="${CONFIG_DIR:-"/config"}"
OLM_MANIFESTS_URL="https://appvia-hub-olm-artifiacts-eu-west-2.s3.eu-west-2.amazonaws.com/0.11.0"
GITHUB_RAW_URL="https://raw.githubusercontent.com"
HELM_DIR="${CONFIG_DIR}/bundles"
HELM_REPOS="${HELM_DIR}/repositories"
HELM_BUNDLES="${HELM_DIR}/charts"
KUBE_DIR="${CONFIG_DIR}/manifests"
OLM_MANIFESTS="${CONFIG_DIR}/olm"

wait-on-pods() {
  namespace=$1
  labels=$2
  delay=${3:-5}
  info "waiting to an initial ${delay} seconds before checking"
  sleep ${delay}

  info "checking for running in namespace: ${namespace}, labels:${labels}"
  for ((i=0; i<24; i++)); do
    if kubectl -n ${namespace} get pods -l ${labels} --no-headers | egrep "[1-9]/[1-9].*Running"; then
      return 0
    fi
    info "no pods currently running or ready yet, sleeping for 5 seconds"
    sleep 5
  done

  return 1
}

provision-gke-istio() {
  info "provisioning istio on the gke platform"
  local namespace="istio-system"
  (
    wait-on-pods ${namespace} 'istio=citadel' &&
    wait-on-pods ${namespace} 'istio=galley' &&
    wait-on-pods ${namespace} 'istio=ingressgateway' &&
    wait-on-pods ${namespace} 'istio=pilot' &&
    wait-on-pods ${namespace} 'istio=mixer' &&
    wait-on-pods ${namespace} 'istio=sidecar-injector' &&
    wait-on-pods ${namespace} 'app=telemetry'
  ) || {
    error "istio has not been provisioned correctly";
    return 1;
  }
  return 0
}

provision-olm() {
  info "provisioning the operator lifecycle manager, version: ${OLM_VERSION}"
  for manifest in olm.crd olm; do
    url="${OLM_MANIFESTS_URL}/${manifest}.yaml"
    info "using the OLM manifest: ${url}"
    if ! kubectl apply -f ${url}; then
      error "failed to apply the manifest: ${url}"
      return 1
    fi
  done

  info "ensuring the olm olm-operator is running"
  if ! wait-on-pods "olm" "app=olm-operator"; then
    error "the olm operator has not come up, exitting"
    return 1
  fi

  info "ensuring the olm catalog-operator is running"
  if ! wait-on-pods "olm" "app=catalog-operator"; then
    error "the catalog operator has not come up, exitting"
    return 1
  fi

  info "ensuring the olm operatoriohub is running"
  if ! wait-on-pods "olm" "olm.catalogSource=operatorhubio-catalog"; then
    error "the catalog operator has not come up, exitting"
    return 1
  fi

  info "ensuring the olm packageserver is running"
  if ! wait-on-pods "olm" "app=packageserver"; then
    error "the catalog operator has not come up, exitting"
    return 1
  fi

  sleep 10
}

provision-olm-framework() {
  info "provisioning the operator framework catalogs"
  for i in ${OLM_MANIFESTS}/catalog*.yaml; do
    # wait for the catalog to come up
    name=$(awk '/name:/ { print $2 }' ${i} | sed -n 1p)
    if [[ -z "${name}" ]]; then
      error "failed to find the name of the catalog in file: ${i}"
      return 1
    fi

    info "installing the catalog: ${i}"
    if ! kubectl apply -f ${i}; then
      error "failed to install the catalog: ${i}"
      return 1
    fi
    if ! wait-on-pods "olm" "olm.catalogSource=${name}"; then
      error "failed to bring up the catalog: ${1}"
      return 1
    fi
  done

  # give some time for the catalog to populate
  sleep 10

  info "provisioning the namespaces"
  for i in ${OLM_MANIFESTS}/namespace*.yaml; do
    info "creating the namespace from file: ${i}"
    if ! kubectl apply -f ${i}; then
      error "failed to create the namespace"
      return 1
    fi
  done

  info "provisioing the operator groups in the namespaces"
  for i in ${OLM_MANIFESTS}/operatorgroups*.yaml; do
    info "creating the operatorgroups from: ${i}"
    if ! kubectl apply -f ${i}; then
      error "failed to create the operatorgroups"
      return 1
    fi
  done

  info "provisioning the operator subscriptions"
  for i in ${OLM_MANIFESTS}/subscription-*.yaml; do
    name=$(awk '/name:/ { print $2 }' ${i} | sed -n 1p)
    namespace=$(awk '/namespace:/ { print $2 }' ${i})
    selector=$(awk '/operator_selector:/ { print $3 }' ${i})
    [[ -z "${selector}"  ]] && { error "selector not found in file: ${i}"; return 1; }
    [[ -z "${namespace}" ]] && { error "namespace not found in file: ${i}"; return 1; }

    info "creating the operator subscription from: ${i}"
    if ! kubectl apply -f ${i}; then
      error "failed to create the subscription"
      return 1
    fi

    info "waiting for the operator to start"
    if ! wait-on-pods ${namespace} "${selector}"; then
      error "failed to start the operator: ${name}, namespace: ${namespace}"
      return 1
    fi

    sleep 5
  done

  info "provisioning the crd packages"
  for i in ${OLM_MANIFESTS}/crd-*.yaml; do
    info "attempting to create crd from file: ${i}"
    if ! kubectl apply -f ${i}; then
      error "failed to create the crd"
      return 1
    fi
    sleep 3
  done

  info "successfully provisioned the olm framework"
}

provision-grafana() {
  # @step: we need to check if the api already get exists
  kubectl -n ${GRAFANA_API_SECRET_NAMESPACE} get secret ${GRAFANA_API_SECRET} && return 0

  local HOSTNAME="${GRAFANA_HOSTNAME}.${GRAFANA_NAMESPACE}.svc.cluster.local"
  local URL="${GRAFANA_SCHEMA}://admin:${GRAFANA_PASSWORD}@${HOSTNAME}:3000"
  local API_KEY_FILE="/tmp/key.json"

  # @step: provison the api for grafana
  info "provisioning the grafana api key, hostname: ${HOSTNAME}"
  cat <<-EOF > /tmp/params.json
  { "name": "api", "role": "Admin", "secondsToLive": 0 }
EOF
  for ((i=0; i<30; i++)) do
    info "attempting to provision a api key for grafana: ${URL}"
    if curl -s -X POST -H "Content-Type: application/json" \
      --data @/tmp/params.json \
      ${URL}/api/auth/keys > ${API_KEY_FILE}; then
      info "successfully provisioned a api key"
      break
    fi
    error "failed to provision the grafana api key, we will retry"
    sleep 10
  done

  # @check if we we able to provision an api key
  [[ -e ${API_KEY_FILE}        ]] || return 1
  [[ -n $(cat ${API_KEY_FILE}) ]] || return 1
  # @check we have valid json
  jq >/dev/null < ${API_KEY_FILE} || return 1
  export GRAFANA_API_KEY=$(jq -r '.key' < ${API_KEY_FILE})

  return 0
}

# deploy-manifests deploys all the files in the manifests directory
deploy-manifests() {
  info "deploying the kubernetes manifests from: ${KUBE_DIR}"
  [[ -d "${KUBE_DIR}" ]] || return 0

  ret=0
  for filename in ${KUBE_DIR}/*; do
    [[ -f "${filename}"          ]] || continue
    [[ ${filename} =~ ^.*\.ya?ml ]] || continue

    info "deploying the manifest: ${filename}"
    if ! kubectl apply -f ${manifest}; then
      error "failed to deploy the manifest: ${filename}"
    fi
  done
  return $ret
}

# deploy-bundles is responsible for deploying charts into the cluster
# loki,bundles/loki,overrides/loki.yaml
deploy-bundles() {
  info "installing helm tiller service"
  helm init --wait --service-account=sysadmin >/dev/null || return 1

  if [[ -f ${HELM_REPOS} ]]; then
    info "installing any repository requirements"
    while IFS=',' read name repository; do
      info "adding the helm repository: ${repository}"
      helm repo add ${name} ${repository} || return 1
    done < <(cat ${HELM_REPOS} | sed /^#/d)

    info "updating the repositories cache"
    helm repo update || return 1
  fi

  if [[ -f ${HELM_BUNDLES} ]]; then
    info "installing the helm charts"
    while IFS=',' read chart namespace options; do
      namespace=${namespace:-"default"}
      name=${chart%%/*}
      if helm ls --deployed | grep ^${name}; then
        info "upgrading chart: ${chart}, namespace: ${namespace}, options: ${options}"
        helm upgrade --install --wait ${name} ${chart} --namespace ${namespace} ${options} || return 1
      else
        info "installing chart: ${chart}, namespace: ${namespace}, options: ${options}"
        helm install --wait ${chart} --namespace ${namespace} --name ${name} ${options} || return 1
      fi
      if [ "${namespace}" != "default" ]; then
        # helm --wait DOES NOT wait for ready deployments properly
        info "waiting for ready deployments on namespace \"${namespace}\""
        for deployment in $(kubectl -n ${namespace} get deployment -o name); do
          kubectl rollout status -n ${namespace} ${deployment}
        done
      fi
    done < <(cat ${HELM_BUNDLES} | sed /^#/d)
  fi
}

if [[ "${ENABLE_ISTIO}" == "true" ]]; then
  if [[ "${PROVIDER}" == "gke" ]]; then
    if ! provision-gke-istio; then
      error "failed to deploy the kubernetes manifests";
      exit 1
    fi
  fi
fi
if ! deploy-manifests; then
  error "failed to deploy the kubernetes manifests";
  exit 1
fi

if ! deploy-bundles; then
  error "failed to deploy the software manifests";
  exit 1
fi

if ! provision-olm; then
  error "failed to provision the olm"
  exit 1
fi

if ! provision-olm-framework; then
  error "failed to provision the olm framework"
  exit 1
fi

if ! provision-grafana; then
  error "failed provision grafana instance"
  exit 1
else
  for ((i=0; i<3; i++)) do
    if kubectl -n ${GRAFANA_API_SECRET_NAMESPACE} create \
      secret generic ${GRAFANA_API_SECRET} \
      --from-literal=key=${GRAFANA_API_KEY}; then
      info "adding the grafana api key secret"
      break
    fi
    error "failed to provision the secret, we will retry with a backoff"
    sleep 5
  done
fi
