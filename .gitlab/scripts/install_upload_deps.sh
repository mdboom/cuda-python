#!/usr/bin/env bash
set -xe

JF_VERSION="2.64.0"

echo "--- Installing dependencies for upload ---"

echo "Install git if missing"
if ! command -v git >/dev/null 2>&1; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git ca-certificates
fi

echo "Install curl"
if ! command -v curl >/dev/null 2>&1; then
  apt-get update
  apt-get install -y curl
fi

echo "Install yq"
curl -L https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o /usr/local/bin/yq
chmod +x /usr/local/bin/yq
yq --version

echo "Install JFrog CLI if missing"
if ! command -v jf >/dev/null 2>&1; then
  echo "Installing JFrog CLI ${JF_VERSION}"
  curl -fL https://releases.jfrog.io/artifactory/jfrog-cli/v2-jf/${JF_VERSION}/jfrog-cli-linux-amd64/jf -o jf
  chmod +x jf
  mv jf /usr/local/bin/jf
fi
jf --version

