#!/usr/bin/env bash
# Teardown – removes everything the POC created in GCP. Asks for confirmation unless --yes is given.
#   scripts/99-teardown.sh [--yes] [--local] [--github-repo]
#     --local        also delete local material: pki/, .secrets/ (Vault unseal key + root token!), build/
#     --github-repo  also delete the GitHub repository (needs: gh auth refresh -s delete_repo)
# Order: stop Flux (so nothing is recreated), remember the persistent disks, delete the GKE cluster,
# delete the left-over disks and the Artifact Registry repository.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./00-env.sh
export PATH="$HOME/.local/bin:$PATH"

YES=false LOCAL=false REPO=false
for a in "$@"; do
  case "$a" in
    --yes) YES=true ;; --local) LOCAL=true ;; --github-repo) REPO=true ;;
    *) echo "unknown option: $a" >&2; exit 1 ;;
  esac
done

echo "This deletes: GKE cluster $CLUSTER ($REGION, project $PROJECT), its persistent disks,"
echo "  Artifact Registry repository connector-self-service"
$LOCAL && echo "  local pki/ .secrets/ build/"
$REPO && echo "  GitHub repository $GH_OWNER/$GH_REPO"
if ! $YES; then read -r -p "Type the cluster name to confirm: " c; [[ "$c" == "$CLUSTER" ]] || { echo "aborted"; exit 1; }; fi

gcloud config set project "$PROJECT" >/dev/null
disks=()
if gcloud container clusters describe "$CLUSTER" --region "$REGION" >/dev/null 2>&1; then
  gcloud container clusters get-credentials "$CLUSTER" --region "$REGION" >/dev/null
  # Stop Flux first so it does not fight the deletion.
  command -v flux >/dev/null && flux suspend ks --all >/dev/null 2>&1 || true
  # PersistentVolumes outlive a cluster deletion as orphaned GCE disks – remember them.
  while read -r h; do [[ -n "$h" ]] && disks+=("$h"); done \
    < <(kubectl get pv -o jsonpath='{range .items[*]}{.spec.csi.volumeHandle}{"\n"}{end}' 2>/dev/null || true)
  echo "deleting cluster (takes several minutes) ..."
  gcloud container clusters delete "$CLUSTER" --region "$REGION" --quiet
else
  echo "cluster $CLUSTER not found – skipping"
fi

# volumeHandle format: projects/<p>/zones/<zone>/disks/<name> (or regions/<region>/disks/<name>)
for h in ${disks[@]+"${disks[@]}"}; do
  name=${h##*/} loc=${h#*/*/}; loc=${loc%%/disks/*}
  case "$loc" in
    zones/*)   gcloud compute disks delete "$name" --zone "${loc#zones/}" --quiet 2>/dev/null || true ;;
    regions/*) gcloud compute disks delete "$name" --region "${loc#regions/}" --quiet 2>/dev/null || true ;;
  esac
  echo "disk $name: deleted (or already gone)"
done

if gcloud artifacts repositories describe connector-self-service --location "$REGION" >/dev/null 2>&1; then
  gcloud artifacts repositories delete connector-self-service --location "$REGION" --quiet
fi

if $LOCAL; then rm -rf pki .secrets build; echo "local material deleted"; fi
if $REPO; then gh repo delete "$GH_OWNER/$GH_REPO" --yes; fi
echo "teardown complete"
