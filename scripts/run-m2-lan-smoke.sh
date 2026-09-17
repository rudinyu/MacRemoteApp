#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
temp_dir="$(mktemp -d "${TMPDIR:-/private/tmp}/macremoteapp-m2-smoke.XXXXXX")"
trap 'rm -rf -- "${temp_dir}"' EXIT

password="$(openssl rand -hex 24)"

make_identity() {
    local name="$1"
    openssl ecparam -name prime256v1 -genkey -noout \
        -out "${temp_dir}/${name}.key"
    openssl req -new -x509 -sha256 \
        -key "${temp_dir}/${name}.key" \
        -out "${temp_dir}/${name}.crt" \
        -days 1 \
        -subj "/CN=MacRemoteApp-${name}" \
        -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
    openssl pkcs12 -export \
        -inkey "${temp_dir}/${name}.key" \
        -in "${temp_dir}/${name}.crt" \
        -out "${temp_dir}/${name}.p12" \
        -name "MacRemoteApp-${name}" \
        -passout "pass:${password}"
}

make_identity host
make_identity viewer

cd "${repo_root}"
MACREMOTEAPP_RUN_M2_LAN_SMOKE=1 \
MACREMOTEAPP_HOST_P12="${temp_dir}/host.p12" \
MACREMOTEAPP_VIEWER_P12="${temp_dir}/viewer.p12" \
MACREMOTEAPP_P12_PASSWORD="${password}" \
swift test \
    --configuration debug \
    --scratch-path .build/m2-lan-smoke \
    --filter M2LanSmokeTests/testM2LoopbackTLSAndSession
