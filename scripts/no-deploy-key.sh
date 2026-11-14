#!/bin/sh
# Run when PROPERTIES_DEPLOY_KEY is missing. In this repository that fails the
# job: a lost or expired secret would otherwise leave every Properties job,
# a required check among them, green while testing nothing. Only a fork,
# which has no key by design, passes with a note: its own Actions (another
# repository's name), or a pull request to this repository from another one
# (HEAD_REPO, the pull request's head repository).
#
#   GITHUB_REPOSITORY=... GITHUB_EVENT_NAME=... HEAD_REPO=... scripts/no-deploy-key.sh
set -eu
ours="WellSpent-OC/WellSpent-Budget"
repository="${GITHUB_REPOSITORY:-}"
if [ "$repository" != "$ours" ]; then
    echo "PROPERTIES_DEPLOY_KEY is not set: $repository is a fork, with no private checkout, so the Properties steps don't run here."
    exit 0
fi
if [ "${GITHUB_EVENT_NAME:-}" = pull_request ] && [ -n "${HEAD_REPO:-}" ] && [ "$HEAD_REPO" != "$ours" ]; then
    echo "PROPERTIES_DEPLOY_KEY is not set: a pull request from $HEAD_REPO gets no secrets, so the Properties steps don't run."
    exit 0
fi
echo "::error::PROPERTIES_DEPLOY_KEY is not set in $ours, so nothing would be tested against Properties. Its secret needs setting again."
exit 1
