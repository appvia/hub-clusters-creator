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
GITHUB_RAW_URL="https://raw.githubusercontent.com"
HELM_DIR="${CONFIG_DIR}/bundles"
HELM_REPOS="${HELM_DIR}/repositories"
HELM_BUNDLES="${HELM_DIR}/charts"
KUBE_DIR="${CONFIG_DIR}/manifests"

provision-olm() {
  info "provisioning the operator lifecycle manager, version: ${OLM_VERSION}"
  for file in {crds,olm}.yaml; do
    if [[ ! -f "/tmp/${file}" ]]; then
      file_link="${GITHUB_RAW_URL}/operator-framework/operator-lifecycle-manager/${OLM_VERSION}/deploy/upstream/quickstart/${file}"
      info "downloading the manifest file: ${file_link}"
      if ! curl -sL "${file_link}" -o /tmp/${file}; then
        error "failed to downloading the manifest: ${file_link}"
        exit 1
      fi
    fi
    if ! kubectl apply -f /tmp/${file}; then
      error "failed to provision olm manifest: ${file}"
      exit 1
    fi
  done

  info "operator lifecycle manager should be provisioning"
}


provision-grafana() {
  # @step: we need to check if the api already get exists
  kubectl -n ${GRAFANA_API_SECRET_NAMESPACE} get secret ${GRAFANA_API_SECRET} && return 0

  local HOSTNAME="${GRAFANA_HOSTNAME}.${GRAFANA_NAMESPACE}.svc.cluster.local"
  local URL="${GRAFANA_SCHEMA}://admin:${GRAFANA_PASSWORD}@${HOSTNAME}"
  local API_KEY_FILE="/tmp/key.json"

  # @step: provison the api for grafana
  info "provisioning the grafana api key, hostname: ${HOSTNAME}"
  cat <<-EOF > /tmp/params.json
  { "name": "api", "role": "Admin", "secondsToLive": 0 }
EOF
  for ((i=0; i<30; i++)) do
    info "attempting to provision a api key for grafana"
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
    done < <(cat ${HELM_REPOS})

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
    done < <(cat ${HELM_BUNDLES})
  fi
}

if ! deploy-manifests; then
  error "failed to deploy the kubernetes manifests";
  exit 1
fi

if ! deploy-bundles; then
  error "failed to deploy the software manifests";
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

if ! provision-olm; then
  error "failed to provision the olm"
  exit
fi
