FROM registry.access.redhat.com/ubi9/ubi-minimal:9.8-1793253163

# Tool versions - update these and rebuild to upgrade
ARG KUBECTL_VERSION=v1.31.0
ARG HELM_VERSION=v3.21.3
ARG K9S_VERSION=v0.32.5
ARG STERN_VERSION=1.30.0
ARG YQ_VERSION=v4.44.3
ARG OC_VERSION=4.16.0
ARG TERRAFORM_VERSION=1.14.3

# Global curl retry and timeout settings for improved download reliability
ARG CURL_RETRY=3
ARG CURL_RETRY_DELAY=2
ARG CURL_MAX_TIME=300

# Install base packages
RUN microdnf install -y \
      tar \
      gzip \
      unzip \
      jq \
      git \
      less \
      vim-enhanced \
      which \
      findutils \
      make \
      procps-ng \
      bind-utils \
      shadow-utils \
      postgresql \
      python3 \
      python3-pip \
      gnupg2 \
      skopeo && \
    pip3 install --no-cache-dir boto3==1.35.86 pyyaml==6.0.2 && \
    microdnf clean all && \
    rm -rf /var/cache/yum

# Install AWS CLI v2
RUN curl --retry ${CURL_RETRY} --retry-delay ${CURL_RETRY_DELAY} --max-time ${CURL_MAX_TIME} -sSfL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip" && \
    unzip -q /tmp/awscliv2.zip -d /tmp && \
    /tmp/aws/install && \
    rm -rf /tmp/aws /tmp/awscliv2.zip

# Install kubectl
RUN curl --retry ${CURL_RETRY} --retry-delay ${CURL_RETRY_DELAY} --max-time ${CURL_MAX_TIME} -sSfL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /usr/local/bin/kubectl && \
    chmod +x /usr/local/bin/kubectl

# Install helm (SHA-256 verified with retry logic)
RUN set -euo pipefail && \
    HELM_PACKAGE="helm-${HELM_VERSION}-linux-amd64.tar.gz" && \
    HELM_BASE_URL="https://get.helm.sh" && \
    curl --retry ${CURL_RETRY} --retry-delay ${CURL_RETRY_DELAY} --max-time ${CURL_MAX_TIME} -sSfO "${HELM_BASE_URL}/${HELM_PACKAGE}" && \
    curl --retry ${CURL_RETRY} --retry-delay ${CURL_RETRY_DELAY} --max-time ${CURL_MAX_TIME} -sSfO "${HELM_BASE_URL}/${HELM_PACKAGE}.sha256sum" && \
    sha256sum -c "${HELM_PACKAGE}.sha256sum" && \
    tar -xzf "${HELM_PACKAGE}" -C /tmp && \
    mv /tmp/linux-amd64/helm /usr/local/bin/helm && \
    chmod +x /usr/local/bin/helm && \
    rm -rf /tmp/linux-amd64 "${HELM_PACKAGE}" "${HELM_PACKAGE}.sha256sum"

# Install k9s
RUN set -euo pipefail && \
    curl --retry ${CURL_RETRY} --retry-delay ${CURL_RETRY_DELAY} --max-time ${CURL_MAX_TIME} -sSfL "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_amd64.tar.gz" | tar -xz -C /tmp && \
    mv /tmp/k9s /usr/local/bin/k9s && \
    chmod +x /usr/local/bin/k9s

# Install stern
RUN set -euo pipefail && \
    curl --retry ${CURL_RETRY} --retry-delay ${CURL_RETRY_DELAY} --max-time ${CURL_MAX_TIME} -sSfL "https://github.com/stern/stern/releases/download/v${STERN_VERSION}/stern_${STERN_VERSION}_linux_amd64.tar.gz" | tar -xz -C /tmp && \
    mv /tmp/stern /usr/local/bin/stern && \
    chmod +x /usr/local/bin/stern

# Install yq
RUN curl --retry ${CURL_RETRY} --retry-delay ${CURL_RETRY_DELAY} --max-time ${CURL_MAX_TIME} -sSfL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" -o /usr/local/bin/yq && \
    chmod +x /usr/local/bin/yq

# Install OpenShift CLI (oc)
RUN set -euo pipefail && \
    curl --retry ${CURL_RETRY} --retry-delay ${CURL_RETRY_DELAY} --max-time ${CURL_MAX_TIME} -sSfL "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OC_VERSION}/openshift-client-linux.tar.gz" | tar -xz -C /tmp && \
    mv /tmp/oc /usr/local/bin/oc && \
    chmod +x /usr/local/bin/oc && \
    rm -f /tmp/kubectl /tmp/README.md


# Install Terraform (GPG-verified)
RUN set -euo pipefail && \
    TF_PACKAGE="terraform_${TERRAFORM_VERSION}_linux_amd64.zip" && \
    TF_BASE_URL="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}" && \
    curl --retry ${CURL_RETRY} --retry-delay ${CURL_RETRY_DELAY} --max-time ${CURL_MAX_TIME} -sSfO "${TF_BASE_URL}/${TF_PACKAGE}" && \
    curl --retry ${CURL_RETRY} --retry-delay ${CURL_RETRY_DELAY} --max-time ${CURL_MAX_TIME} -sSfO "${TF_BASE_URL}/terraform_${TERRAFORM_VERSION}_SHA256SUMS" && \
    curl --retry ${CURL_RETRY} --retry-delay ${CURL_RETRY_DELAY} --max-time ${CURL_MAX_TIME} -sSfO "${TF_BASE_URL}/terraform_${TERRAFORM_VERSION}_SHA256SUMS.sig" && \
    gpg --batch --keyserver keyserver.ubuntu.com --recv-keys \
      C874011F0AB405110D02105534365D9472D7468F || \
    gpg --batch --keyserver keys.openpgp.org --recv-keys \
      C874011F0AB405110D02105534365D9472D7468F || \
    gpg --batch --keyserver pgp.mit.edu --recv-keys \
      C874011F0AB405110D02105534365D9472D7468F && \
    gpg --batch --verify "terraform_${TERRAFORM_VERSION}_SHA256SUMS.sig" \
      "terraform_${TERRAFORM_VERSION}_SHA256SUMS" && \
    grep "${TF_PACKAGE}" "terraform_${TERRAFORM_VERSION}_SHA256SUMS" | sha256sum -c - && \
    unzip -o "${TF_PACKAGE}" -d /tmp/tf-bin && \
    mv /tmp/tf-bin/terraform /usr/local/bin/ && \
    rm -rf "${TF_PACKAGE}" "terraform_${TERRAFORM_VERSION}_SHA256SUMS" \
      "terraform_${TERRAFORM_VERSION}_SHA256SUMS.sig" /tmp/tf-bin

# Copy platform scripts (root-owned, non-writable at runtime)
COPY scripts/ /opt/platform/scripts/
RUN chmod +x /opt/platform/scripts/* && \
    chown -R root:root /opt/platform/scripts && \
    chmod -R a-w /opt/platform/scripts

# Run as non-root; give UID 65534 its own writable home, leave scripts read-only
RUN mkdir -p /opt/platform/home && chown 65534:65534 /opt/platform/home
ENV HOME=/opt/platform/home
ENV PATH="/opt/platform/scripts:${PATH}"
USER 65534
