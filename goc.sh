#!/usr/bin/env bash
# GOC - GitOps Container

set -Eeuo pipefail
temp_dir=$(mktemp -d /tmp/goc.XXXXXX)

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

function notify {
  local stack="$1"
  local message="$2"

  if is_true "${GOC_NOTIFICATIONS}" && [ -n "${GOC_NOTIFICATION_URL}" ]; then
    pchange "[+] Sending notification for stack ${stack}..."
    apprise -v -t "[goc] Stack update for ${stack}" -b "${message}" "${GOC_NOTIFICATION_URL}"
  fi
}

function is_true {
  local value="$1"
  [[ "$value" == "true" || "$value" == "1" || "$value" == "yes" || "$value" == "on" ]]
}

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

pinfo "[+] Starting GOC controller..."
notify "GLOBAL" "Starting GOC controller!"

while [ true ]; do
  # clone or update the repository
  if [ -d "${temp_dir}/.git" ]; then
    cd "${temp_dir}"
    git pull || (
      is_true "${GOC_REPOSITORY_RESET}" && (git fetch; git reset --hard "origin/${GOC_REPOSITORY_BRANCH}")
    )
  else
    git clone "${GOC_REPOSITORY}" "${temp_dir}" --branch "${GOC_REPOSITORY_BRANCH}" --single-branch
  fi

  # iterate over every stack defined in the configuration
  for stack in $(yq -r '.stacks | keys()[]' "${temp_dir}/${GOC_REPOSITORY_CONFIG}"); do
    pinfo "[+] Processing stack: ${stack}"

    # extract source and target directories from the configuration
    source_dir="${temp_dir}/$(yq ".stacks.${stack}.repo_dir" "${temp_dir}/${GOC_REPOSITORY_CONFIG}")"
    target_dir="${GOC_WORKSPACE}/$(yq ".stacks.${stack}.target_dir" "${temp_dir}/${GOC_REPOSITORY_CONFIG}")"
    compose_file=$(yq ".stacks.${stack}.compose_file // \"\"" "${temp_dir}/${GOC_REPOSITORY_CONFIG}")

    # check for config changes
    if ! diff -qr "${source_dir}" "${target_dir}" >/dev/null 2>&1; then
      pchange "[+] Changes detected in stack ${stack}. Updating..."

      # sync changes from source to target directory
      rsync -r "$(realpath $source_dir)/" "$(realpath $target_dir)/"

      compose_params="--project-directory ${target_dir} up -d --force-recreate"
      compose_file_param=""

      if [ ! -z "${compose_file}" ]; then
        compose_file_param="--file ${target_dir}/${compose_file}"
      fi

      # update the stack
      { set +e; docker_output=$(docker compose ${compose_file_param} ${compose_params} 2>&1 >&3 3>&-); export returncode=$?; set -e; } 3>&1

      if [ ${returncode} -eq 0 ]; then
        pchange "[+] Stack ${stack} updated successfully!"
        notify "${stack}" "Changes in stack have been applied successfully."
      else
        perr "[!] Failed to update stack ${stack}. Output: ${docker_output}"
        echo "${docker_output}"
        notify "${stack}" "Failed to update stack. Output: ${docker_output}"
      fi
    else
      pinfo "[+] No changes detected in stack ${stack}. Skipping update."
    fi
  done

  sleep "${GOC_INTERVAL}"
done
