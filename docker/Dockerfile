FROM fedora:30
MAINTAINER Rohith Jayawardene <gambol99@gmail.com>

ENV ARCH="amd64" \
    HELM_VERSION="2.14.1" \
    KUBECTL_VERSION="1.14.0"

RUN dnf install -y bash curl jq findutils

RUN curl -sL https://storage.googleapis.com/kubernetes-release/release/v${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl -o /usr/bin/kubectl && \
    curl -sL https://get.helm.sh/helm-v${HELM_VERSION}-linux-${ARCH}.tar.gz | tar -C /tmp -xzf - && mv /tmp/linux-${ARCH}/helm /usr/bin/helm && \
    chmod +x /usr/bin/kubectl /usr/bin/helm && \
    rm -rf /tmp/linux-${ARCH}

RUN kubectl version --client && \
    helm version --client

COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT [ "/entrypoint.sh" ]
