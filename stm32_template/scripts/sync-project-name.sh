#!/bin/zsh

set -euo pipefail

cd "$(dirname "$0")/.."

project_name="${PWD:t}"
current_name="$(sed -nE 's/^name = "(.*)"/\1/p' Cargo.toml | head -n 1)"

if [[ -z "${current_name}" ]]; then
  echo "Failed to read package name from Cargo.toml" >&2
  exit 1
fi

if [[ "${current_name}" == "${project_name}" ]]; then
  exit 0
fi

tmp_file="$(mktemp)"

awk -v new_name="${project_name}" '
  BEGIN { in_package = 0; updated = 0 }
  /^\[package\]$/ { in_package = 1; print; next }
  /^\[/ && $0 != "[package]" { in_package = 0 }
  in_package && /^name = "/ && !updated {
    print "name = \"" new_name "\""
    updated = 1
    next
  }
  { print }
' Cargo.toml > "${tmp_file}"

mv "${tmp_file}" Cargo.toml
echo "Updated package name: ${current_name} -> ${project_name}"
