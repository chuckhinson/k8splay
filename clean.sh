#!/bin/bash

set -euo pipefail

rm worker-*
rm *.pem
rm *.csr
rm *.kubeconfig
rm encryption-config.yaml