# frozen_string_literal: true

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

DEFAULT_PSP_CLUSTER_ROLE = <<~YAML
  apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRole
  metadata:
    name: default:psp
  rules:
  - apiGroups:
    - policy
    resourceNames:
    - gce.unprivileged-addon
    resources:
    - podsecuritypolicies
    verbs:
    - use
YAML

DEFAULT_PSP_CLUSTERROLE_BINDING = <<~YAML
  apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRoleBinding
  metadata:
    name: default:psp
  roleRef:
    apiGroup: rbac.authorization.k8s.io
    kind: ClusterRole
    name: default:psp
  subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: system:authenticated
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: system:serviceaccounts
YAML

DEFAULT_CLUSTER_ADMIN_ROLE = <<~YAML
  apiVersion: v1
  kind: ServiceAccount
  metadata:
    name: sysadmin
    namespace: kube-system
YAML

DEFAULT_CLUSTER_ADMIN_BINDING = <<~YAML
  apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRoleBinding
  metadata:
    name: cluster:admin
  roleRef:
    apiGroup: rbac.authorization.k8s.io
    kind: ClusterRole
    name: cluster-admin
  subjects:
  - kind: ServiceAccount
    name: sysadmin
    namespace: kube-system
YAML

DEFAULT_BOOTSTRAP_JOB = <<-YAML
  apiVersion: batch/v1
  kind: Job
  metadata:
    name: hub-bootstrap
    namespace: kube-system
  spec:
    backoffLimit: 4
    template:
      spec:
        serviceAccountName: sysadmin
        restartPolicy: OnFailure
        containers:
        - name: bootstrap
          image: quay.io/appvia/hub-bootstrap:latest
          imagePullPolicy: Always
          env:
          - name: CONFIG_DIR
            value: /config
          volumeMounts:
          - name: bundle
            mountPath: /config/bundles
        volumes:
        - name: bundle
          configMap:
            name: hub-bootstrap-bundle
YAML
