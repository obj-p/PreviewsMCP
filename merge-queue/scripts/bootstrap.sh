#!/usr/bin/env bash
# Bootstrap a repo's merge-queue gate, idempotently. Registers the deploy key
# (the gate's sole bypass actor) and the account signing key, creates the two
# rulesets (gate + required signatures), commits allowed_signers, and disables
# Actions. Re-running is a no-op once everything is in place.
#
#   KEY_HOME=~/.config/merge-queue bootstrap.sh <owner/repo>
#
# The keys come from the age-encrypted bundle in KEY_HOME. See the two-ruleset
# trust boundary in docs/local-merge-queue-plan.md.
set -euo pipefail

REPO="${1:?usage: bootstrap.sh <owner/repo>}"
KEY_HOME="${KEY_HOME:-$HOME/.config/merge-queue}"

note() { printf '==> %s\n' "$1"; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
age -d -i "$KEY_HOME/identity.txt" "$KEY_HOME/bundle.age" \
  | tar -C "$STAGE" -xf - signing_key.pub deploy_key.pub
SIGN_PUB="$(cat "$STAGE/signing_key.pub")"
DEPLOY_PUB="$(cat "$STAGE/deploy_key.pub")"
# Compare keys by type+body only; the trailing comment is not significant.
key_body() { awk '{print $1, $2}'; }
SIGN_BODY="$(printf '%s' "$SIGN_PUB" | key_body)"
DEPLOY_BODY="$(printf '%s' "$DEPLOY_PUB" | key_body)"

# A commit verifies only when its committer email is linked to the account that
# owns the signing key, so the principal is the account's noreply address.
GH_ID="$(gh api user --jq .id)"
GH_LOGIN="$(gh api user --jq .login)"
PRINCIPAL="${GH_ID}+${GH_LOGIN}@users.noreply.github.com"

# 1. Deploy key (read-write). The ruleset bypass covers the whole deploy-key
#    category, so this must stay the only read-write deploy key on the repo.
if gh api "repos/$REPO/keys" --jq '.[].key' | key_body | grep -qxF "$DEPLOY_BODY"; then
  note "deploy key already registered"
else
  gh api "repos/$REPO/keys" -f title="merge-queue-deploy" -f key="$DEPLOY_PUB" \
    -F read_only=false >/dev/null
  note "deploy key registered (read-write)"
fi

# 2. Account signing key, so GitHub marks merge-queue commits verified.
if gh api user/ssh_signing_keys --jq '.[].key' | key_body | grep -qxF "$SIGN_BODY"; then
  note "signing key already on account"
else
  gh api user/ssh_signing_keys -f title="merge-queue-signing" -f key="$SIGN_PUB" >/dev/null
  note "signing key registered on account"
fi

# 3. allowed_signers, committed before any ruleset is active (the account can
#    still push). Lets anyone verify main locally with the same principal.
ALLOWED="$PRINCIPAL $SIGN_BODY"
CURRENT="$(gh api "repos/$REPO/contents/allowed_signers" --jq '.content' 2>/dev/null \
  | base64 -d 2>/dev/null || true)"
if [ "$CURRENT" = "$ALLOWED" ]; then
  note "allowed_signers already current"
else
  SHA="$(gh api "repos/$REPO/contents/allowed_signers" --jq '.sha' 2>/dev/null || true)"
  gh api -X PUT "repos/$REPO/contents/allowed_signers" \
    -f message="merge-queue: register allowed_signers" \
    -f content="$(printf '%s\n' "$ALLOWED" | base64)" \
    ${SHA:+-f sha="$SHA"} >/dev/null
  note "allowed_signers committed"
fi

# 4. Two rulesets. The gate blocks every update to the default branch and names
#    the deploy key as the sole bypass; signatures are a separate ruleset with
#    an empty bypass, so even the deploy key must push signed commits.
ruleset_id() { gh api "repos/$REPO/rulesets" --jq ".[] | select(.name==\"$1\") | .id"; }

if [ -n "$(ruleset_id merge-queue-gate)" ]; then
  note "gate ruleset already present"
else
  gh api -X POST "repos/$REPO/rulesets" --input - >/dev/null <<JSON
{ "name": "merge-queue-gate", "target": "branch", "enforcement": "active",
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
  "rules": [{"type": "update"}, {"type": "deletion"}, {"type": "non_fast_forward"}],
  "bypass_actors": [{"actor_type": "DeployKey", "bypass_mode": "always"}] }
JSON
  note "gate ruleset created"
fi

if [ -n "$(ruleset_id merge-queue-signatures)" ]; then
  note "signatures ruleset already present"
else
  gh api -X POST "repos/$REPO/rulesets" --input - >/dev/null <<JSON
{ "name": "merge-queue-signatures", "target": "branch", "enforcement": "active",
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
  "rules": [{"type": "required_signatures"}], "bypass_actors": [] }
JSON
  note "signatures ruleset created"
fi

# 5. No GitHub CI in this model. Disable Actions.
if [ "$(gh api "repos/$REPO/actions/permissions" --jq '.enabled')" = "false" ]; then
  note "actions already disabled"
else
  gh api -X PUT "repos/$REPO/actions/permissions" -F enabled=false
  note "actions disabled"
fi

note "bootstrap complete for $REPO (principal $PRINCIPAL)"
