#!/usr/bin/env bash
# GOC - GitOps Container

set -Eeuo pipefail

# ensure variable defaults
: "${DEBUG:=false}"
: "${GOC_WORKSPACE:?GOC_WORKSPACE not set or empty}"
: "${GOC_REPOSITORY:?GOC_REPOSITORY not set or empty}"
: "${GOC_REPOSITORY_BRANCH:=main}"
: "${GOC_REPOSITORY_CONFIG:=goc.yaml}"
: "${GOC_REPOSITORY_RESET:=false}"
: "${GOC_INTERVAL:=30}"
: "${GOC_DRY_RUN:=false}"
: "${GOC_NOTIFICATIONS:=false}"
: "${GOC_NOTIFICATION_URL:=""}"
: "${GOC_NOTIFICATION_START_STOP:=false}"

GOC_REPOSITORY_CLEANED=$(echo "${GOC_REPOSITORY}" | sed -E 's/([a-zA-Z0-9_])+@//g') # remove any git reference like "PAT@"
TEMP_DIR=$(mktemp -d /tmp/goc.XXXXXX)

function exit_handler {
  pinfo "Exiting goc controller..."
  is_true "${GOC_NOTIFICATION_START_STOP}" && notify "controller stopped" "The controller has been stopped." "🛑"
}

trap exit_handler EXIT

function pinfo {
  is_true "${GOC_DRY_RUN}" && prefix="[DRY RUN]" || prefix=""
  printf "\033[32m%s\033[0m\n" "[$(date -Iseconds)]${prefix} $*"
}

function pchange {
  is_true "${GOC_DRY_RUN}" && prefix="[DRY RUN]" || prefix=""
  printf "\033[34m%s\033[0m\n" "[$(date -Iseconds)]${prefix} $*"
}

function pwarn {
  is_true "${GOC_DRY_RUN}" && prefix="[DRY RUN]" || prefix=""
  printf "\033[33m%s\033[0m\n" "[$(date -Iseconds)]${prefix} $*"
}

function perr {
  is_true "${GOC_DRY_RUN}" && prefix="[DRY RUN]" || prefix=""
  printf "\033[31m%s\033[0m\n" "[$(date -Iseconds)]${prefix} $*"
}

function pdebug {
  is_true "${GOC_DRY_RUN}" && prefix="[DRY RUN]" || prefix=""

  if is_true "${DEBUG}"; then
    printf "\033[35m%s\033[0m\n" "[$(date -Iseconds)]${prefix} $*"
  fi
}

function is_true {
  local value="$1"
  [[ "$value" == "true" || "$value" == "1" || "$value" == "yes" || "$value" == "on" ]]
}

function notify {
  local title="$1"
  local message="${2:-"_"}"
  local notification_icon="${3:-""}"

  if is_true "${GOC_NOTIFICATIONS}" && [ -n "${GOC_NOTIFICATION_URL}" ]; then
    pdebug "Sending notification: **[goc] ${title}** ${message}"
    apprise -v -t ":" -b "${notification_icon} **${title}**: ${message}" "${GOC_NOTIFICATION_URL}" ""
  fi
}

function git_update {
  if [ -d "${TEMP_DIR}/.git" ]; then
    pdebug "Repository already exists, updating..."

    cd "${TEMP_DIR}"
    git pull || (
      # pull failed, reset the repository
      is_true "${GOC_REPOSITORY_RESET}" && (
        pdebug "Failed to pull repository, resetting..."
        git fetch
        git reset --hard "origin/${GOC_REPOSITORY_BRANCH}"
      ) || return 1
    )
    return
  fi

  pdebug "Cloning repository..."
  git clone "${GOC_REPOSITORY}" "${TEMP_DIR}" --branch "${GOC_REPOSITORY_BRANCH}" --single-branch
}

function config_entry {
  local key="$1"
  local default="${2:-""}"

  v=$(yq -er "${key}" "${TEMP_DIR}/${GOC_REPOSITORY_CONFIG}" 2>/dev/null)
  return_code=$?

  if [ $return_code -eq 0 ]; then
    echo "${v}"
    return
  fi

  if [ $# -gt 2 ]; then
    # If the key is not found and a default is given, return that
    echo "${default}"
    return
  fi

  return
}

function compose {
  local stack="$1"
  local project_dir="$2"
  local compose_file="$3"

  local compose_params="--project-directory ${project_dir} up -d --force-recreate"
  local compose_file_param=""

  if [ ! -z "${compose_file}" ]; then
    compose_file_param="--file ${project_dir}/${compose_file}"
  fi

  # update the stack
  pdebug "[${stack}] Updating stack with command: docker compose ${compose_file_param} ${compose_params}"
  is_true "${GOC_DRY_RUN}" && return

  {
    set +e
    docker_output=$(docker compose ${compose_file_param} ${compose_params} 2>&1 >&3 3>&-)
    export return_code=$?
    set -e
  } 3>&1

  if [ ${return_code} -eq 0 ]; then
    pchange "[${stack}] Stack successfully updated!"
    notify "[${stack}] [OK]" "Changes in stack have been applied successfully." "✅"
  else
    perr "[${stack}] Failed to update stack. Output:"
    echo "${docker_output}"
    notify "[${stack}] [ERROR]" "Failed to update stack. Output: ${docker_output}. Check repository for changes: ${GOC_REPOSITORY_CLEANED}" "❌"
  fi
}

##########

pinfo "Starting goc controller..."
pinfo "  - Workspace: ${GOC_WORKSPACE}"
pinfo "  - Repository: ${GOC_REPOSITORY_CLEANED}"
pinfo "  - Branch: ${GOC_REPOSITORY_BRANCH}"
pinfo "  - Config: ${GOC_REPOSITORY_CONFIG}"
pinfo "  - Interval: ${GOC_INTERVAL}s"

is_true "${GOC_NOTIFICATION_START_STOP}" && notify "Starting controller!" "The controller has been started!" "🚀"

while [ true ]; do
  # clone or update the repository
  git_update

  # iterate over every stack defined in the configuration
  for stack in $(config_entry '.stacks | keys[]'); do
    pinfo "[${stack}] Processing stack..."

    # extract source and target directories from the configuration
    source_dir="${TEMP_DIR}/$(config_entry .stacks.${stack}.repo_dir)"
    target_dir="${GOC_WORKSPACE}/$(config_entry .stacks.${stack}.target_dir)"
    compose_file=$(config_entry .stacks.${stack}.compose_file)

    # check for config changes
    if [ ! "$(cd "${source_dir}"; find . -type f -exec diff -q {} "${target_dir}/{}" \; 2>&1)" ]; then
      pinfo "[${stack}] No changes detected in stack ${stack}. Skipping update."
      continue
    fi

    pchange "[${stack}] Changes detected - updating..."

    # sync changes from source to target directory
    mkdir -p "${target_dir}" || true
    pdebug "[${stack}] Syncing changes from $(realpath $source_dir) to $(realpath $target_dir)"

    # check if dry run is enabled
    if is_true "${GOC_DRY_RUN}"; then
      pchange "[${stack}] Skip rsync due to dry run mode..."

      continue
    fi

    # check if the target directory is ignored
    if test -f "$(realpath $target_dir)/.gocignore"; then
      pchange "[${stack}] Ignoring stack due to .gocignore file..."
      notify "[${stack}] [IGNORED]" "Ignoring stack temporarily due to .gocignore file..." "⏩"

      continue
    fi

    # sync changes
    rsync -r "$(realpath $source_dir)/" "$(realpath $target_dir)/"

    # run compose command
    compose "${stack}" "${target_dir}" "${compose_file}"
  done

  pdebug "Sleeping for ${GOC_INTERVAL} seconds before next check..."
  sleep "${GOC_INTERVAL}"
done
