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
HELM_DIR="${CONFIG_DIR}/bundles"
HELM_REPOS="${HELM_DIR}/repositories"
HELM_BUNDLES="${HELM_DIR}/charts"
KUBE_DIR="${CONFIG_DIR}/manifests"

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
      info "installing chart: ${chart}, namespace: ${namespace}, options: ${options}"
      helm upgrade --install --wait ${chart} --namespace ${namespace} ${options} || return 1
    done < <(cat ${HELM_BUNDLES})
  fi
}

deploy-manifests || {
  error "failed to deploy the kubernetes manifests";
  exit 1;
}
deploy-bundles || {
  error "failed to deploy the software manifests";
  exit 1;
}

