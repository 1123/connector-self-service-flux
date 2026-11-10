#!/usr/bin/env bash
# Phase 5 – create the public GitHub repository, push the code and bootstrap Flux against it.
# Flux gets a read-only deploy key; it never writes to the repository after bootstrap.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./00-env.sh
if ! gh repo view "$GH_OWNER/$GH_REPO" >/dev/null 2>&1; then
  gh repo create "$GH_OWNER/$GH_REPO" --public \
    --description "Self-service Kafka connectors on Confluent Platform (CFK) synced by Flux"
fi
git remote get-url origin >/dev/null 2>&1 || git remote add origin "https://github.com/$GH_OWNER/$GH_REPO.git"
git push -u origin main

GITHUB_TOKEN=$(gh auth token) flux bootstrap github \
  --owner="$GH_OWNER" --repository="$GH_REPO" --personal --branch=main --path=clusters/poc \
  --read-write-key=false
git pull --ff-only origin main
