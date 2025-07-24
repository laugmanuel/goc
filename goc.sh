#!/usr/bin/env bash

temp_dir=$(mktemp -d /tmp/goc.XXXXXX)

echo "[+] Starting GOC container..."

while [ true ]; do
  test -d "${temp_dir}/.git" && (cd "${temp_dir}" && git pull) || git clone "${GOC_REPOSITORY}" "${temp_dir}" --branch "${GOC_REPOSITORY_BRANCH:-main}" --single-branch

  for stack in $(yq -r '.stacks | keys()[]' "${temp_dir}/${GOC_REPOSITORY_CONFIG}"); do
    echo "[+] Processing stack: ${stack}"

    source_dir="${temp_dir}/$(yq ".stacks.${stack}.repo_dir" "${temp_dir}/${GOC_REPOSITORY_CONFIG}")"
    target_dir="${GOC_WORKSPACE}/$(yq ".stacks.${stack}.target_dir" "${temp_dir}/${GOC_REPOSITORY_CONFIG}")"
    compose_file=$(yq ".stacks.${stack}.compose_file // \"\"" "${temp_dir}/${GOC_REPOSITORY_CONFIG}")

    if ! diff -qr "${source_dir}" "${target_dir}" >/dev/null 2>&1; then
      echo "[+] Changes detected in stack ${stack}. Updating..."
      rsync -r "$(realpath $source_dir)/" "$(realpath $target_dir)/"

      echo "[+] Restarting docker compose stack ${stack}..."
      (
        cd "${target_dir}"
        if [ -z "${compose_file}" ]; then
          docker compose up -d --force-recreate
        else
          docker compose -f "${compose_file}" up -d --force-recreate
        fi
      )
    else
      echo "[+] No changes detected in stack ${stack}. Skipping update."
    fi
  done

  sleep "${GOC_INTERVAL:-1}"
  echo "--------------------------------------"
done
