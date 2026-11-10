#!/usr/bin/env bash
# Phase 5 – create the public GitHub repository and install Flux in pull-only mode.
# The repo is public, so Flux reads it over HTTPS without any credential and never writes to it.
# Pushing the code is done by the admin (git push / git push-external) – this script does not push.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./00-env.sh
export PATH="$HOME/.local/bin:$PATH"
if ! gh repo view "$GH_OWNER/$GH_REPO" >/dev/null 2>&1; then
  gh repo create "$GH_OWNER/$GH_REPO" --public \
    --description "Self-service Kafka connectors on Confluent Platform (CFK) synced by Flux"
fi
git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/$GH_OWNER/$GH_REPO.git"
git fetch -q origin main 2>/dev/null && git merge-base --is-ancestor HEAD origin/main \
  || echo "WARNING: local main is not pushed yet – push it before Flux can sync it." >&2

flux check --pre
flux install
kubectl apply -f bootstrap/flux-sync.yaml
flux reconcile source git flux-system
