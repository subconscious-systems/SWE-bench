#!/usr/bin/env bash
# Install AWS CLI v2 (official bundle). Idempotent.
# Ubuntu 24.04+ has no awscli apt package — use this instead of apt-get install awscli.
set -euo pipefail

if command -v aws >/dev/null 2>&1; then
  echo "aws cli already installed: $(aws --version 2>&1 | head -1)"
  exit 0
fi

machine="$(uname -m)"
case "$machine" in
  x86_64) aws_arch=x86_64 ;;
  aarch64|arm64) aws_arch=aarch64 ;;
  *)
    echo "error: unsupported architecture for AWS CLI v2: $machine" >&2
    exit 1
    ;;
esac

if ! command -v unzip >/dev/null 2>&1; then
  echo "error: unzip required (install via bootstrap base packages)" >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "downloading AWS CLI v2 (${aws_arch}) ..."
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${aws_arch}.zip" -o "$tmp/awscliv2.zip"
unzip -q "$tmp/awscliv2.zip" -d "$tmp"
"$tmp/aws/install" -i /usr/local/aws-cli -b /usr/local/bin --update
aws --version
