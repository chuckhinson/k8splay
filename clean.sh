#!/bin/bash

set -euo pipefail

# Use this script to clean up all of the files created by prepare-files.sh

rm worker-*
rm *.pem
rm *.csr
rm *.kubeconfig
rm encryption-config.yaml