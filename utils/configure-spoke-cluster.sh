#!/bin/bash

set -e

# shellcheck source=./utils/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

printlog title "Setting up pull secret and ImageDigestMirrorSet for spoke cluster"
QUAY_TOKEN=${QUAY_TOKEN:-$(get_quay_token_from_file)}
if [[ -z "${QUAY_TOKEN}" ]]; then
  printlog error "QUAY_TOKEN must be set, or a quay.io token provided in a docker config file at utils/.docker/config.json"
  exit 1
fi

setup_pull_secret "${QUAY_TOKEN}"
setup_image_mirrors

printlog title "Setup complete!"
