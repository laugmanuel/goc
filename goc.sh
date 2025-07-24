#!/usr/bin/env bash
# GOC - GitOps Container

set -Eeuo pipefail

function pinfo {
 printf "\033[32m%s\033[0m\n" "[$(date -Iseconds)] $*"
}

function pchange {
  printf "\033[34m%s\033[0m\n" "[$(date -Iseconds)] $*"
}

function pwarn {
  printf "\033[33m%s\033[0m\n" "[$(date -Iseconds)] $*"
}

function perr {
  printf "\033[31m%s\033[0m\n" "[$(date -Iseconds)] $*"
}

function pdebug {
  if [ "${DEBUG:-false}" == "true" ]; then
    printf "\033[35m%s\033[0m\n" "[$(date -Iseconds)] $*"
  fi
}

function notify {
  local title="$1"
  local message="${2:-"_"}"

  if is_true "${GOC_NOTIFICATIONS}" && [ -n "${GOC_NOTIFICATION_URL}" ]; then
    pdebug "Sending notification: **[goc] ${title}** ${message}"
    apprise -v -t "**[goc] ${title}**" -b "${message}" "${GOC_NOTIFICATION_URL}"   ""
  fi
}

function is_true {
  local value="$1"
  [[ "$value" == "true" || "$value" == "1" || "$value" == "yes" || "$value" == "on" ]]
}

function exit_handler {
  pinfo "Exiting goc controller..."
  notify "controller stopped" "The controller has been stopped."
}

trap exit_handler EXIT
temp_dir=$(mktemp -d /tmp/goc.XXXXXX)

##########

# ensure variable defaults
: "${GOC_WORKSPACE:?GOC_WORKSPACE not set or empty}"
: "${GOC_REPOSITORY:?GOC_REPOSITORY not set or empty}"
: "${GOC_REPOSITORY_BRANCH:=main}"
: "${GOC_REPOSITORY_CONFIG:=goc.yaml}"
: "${GOC_REPOSITORY_RESET:=false}"
: "${GOC_INTERVAL:=30}"
: "${GOC_NOTIFICATIONS:=false}"
: "${GOC_NOTIFICATION_URL:=""}"

GOC_REPOSITORY_CLEANED=$(echo "${GOC_REPOSITORY}" | sed -E 's/([a-zA-Z0-9_])+@//g') # remove any git reference like "PAT@"

pinfo "[GLOBAL] Starting goc controller..."
pinfo "  - Workspace: ${GOC_WORKSPACE}"
pinfo "  - Repository: ${GOC_REPOSITORY_CLEANED}"
pinfo "  - Branch: ${GOC_REPOSITORY_BRANCH}"
pinfo "  - Config: ${GOC_REPOSITORY_CONFIG}"
pinfo "  - Interval: ${GOC_INTERVAL}s"

notify "Starting controller!" "The controller has been started!"

while [ true ]; do
  # clone or update the repository
  if [ -d "${temp_dir}/.git" ]; then
    pdebug "Repository already exists, updating..."
    cd "${temp_dir}"
    git pull || (
      pdebug "Failed to pull repository, resetting..."
      is_true "${GOC_REPOSITORY_RESET}" && (git fetch; git reset --hard "origin/${GOC_REPOSITORY_BRANCH}") || false
    )
  else
    pdebug "Cloning repository..."
    git clone "${GOC_REPOSITORY}" "${temp_dir}" --branch "${GOC_REPOSITORY_BRANCH}" --single-branch
  fi

  # iterate over every stack defined in the configuration
  for stack in $(yq -r '.stacks | keys()[]' "${temp_dir}/${GOC_REPOSITORY_CONFIG}"); do
    pinfo "[${stack}] Processing stack..."

    # extract source and target directories from the configuration
    source_dir="${temp_dir}/$(yq ".stacks.${stack}.repo_dir" "${temp_dir}/${GOC_REPOSITORY_CONFIG}")"
    target_dir="${GOC_WORKSPACE}/$(yq ".stacks.${stack}.target_dir" "${temp_dir}/${GOC_REPOSITORY_CONFIG}")"
    compose_file=$(yq ".stacks.${stack}.compose_file // \"\"" "${temp_dir}/${GOC_REPOSITORY_CONFIG}")

    # check for config changes
    if [ ! -z "$(cd "${source_dir}"; find . -type f -exec diff -q {} "${target_dir}/{}" \;)" ]; then
      pchange "[${stack}] Changes detected - updating..."

      # sync changes from source to target directory
      pdebug "Syncing changes from $(realpath $source_dir)/ to $(realpath $target_dir)/"
      rsync -r "$(realpath $source_dir)/" "$(realpath $target_dir)/"

      compose_params="--project-directory ${target_dir} up -d --force-recreate"
      compose_file_param=""

      if [ ! -z "${compose_file}" ]; then
        compose_file_param="--file ${target_dir}/${compose_file}"
      fi

      # update the stack
      pdebug "Updating stack with command: docker compose ${compose_file_param} ${compose_params}"
      { set +e; docker_output=$(docker compose ${compose_file_param} ${compose_params} 2>&1 >&3 3>&-); export returncode=$?; set -e; } 3>&1

      if [ ${returncode} -eq 0 ]; then
        pchange " Stack successfully updated!"
        notify "[${stack}] [OK]" "Changes in stack have been applied successfully."
      else
        perr "[${stack}] Failed to update stack. Output:"
        echo "${docker_output}"
        notify "[${stack}] [ERROR]" "Failed to update stack. Output: ${docker_output}. Check repository for changes: ${GOC_REPOSITORY_CLEANED}"
      fi
    else
      pinfo "[${stack}] No changes detected in stack ${stack}. Skipping update."
    fi
  done

  pdebug "Sleeping for ${GOC_INTERVAL} seconds before next check..."
  sleep "${GOC_INTERVAL}"
done
