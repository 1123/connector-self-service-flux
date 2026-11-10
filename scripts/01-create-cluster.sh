#!/usr/bin/env bash
# Phase 1 – regional GKE cluster (3 zones, 1 node per zone) + Artifact Registry for the custom Connect image.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./00-env.sh
ZONES=${REGION}-a,${REGION}-b,${REGION}-c

gcloud config set project "$PROJECT" >/dev/null
gcloud services enable container.googleapis.com artifactregistry.googleapis.com

if ! gcloud container clusters describe "$CLUSTER" --region "$REGION" >/dev/null 2>&1; then
  gcloud container clusters create "$CLUSTER" --region "$REGION" --node-locations "$ZONES" \
    --num-nodes 1 --machine-type n2-standard-8 --disk-type pd-ssd --disk-size 100 \
    --enable-dataplane-v2 --labels "$LABELS" --release-channel regular --quiet
fi
gcloud container clusters get-credentials "$CLUSTER" --region "$REGION"

gcloud artifacts repositories describe connector-self-service --location="$REGION" >/dev/null 2>&1 ||
  gcloud artifacts repositories create connector-self-service --repository-format=docker \
    --location="$REGION" --labels "$LABELS"
# Nodes run as the default compute SA → grant pull access on this repository only.
NODE_SA="$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')-compute@developer.gserviceaccount.com"
gcloud artifacts repositories add-iam-policy-binding connector-self-service --location="$REGION" \
  --member "serviceAccount:$NODE_SA" --role roles/artifactregistry.reader --condition=None >/dev/null

kubectl get nodes -L topology.kubernetes.io/zone
