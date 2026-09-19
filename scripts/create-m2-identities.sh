#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $0 OUTPUT_DIRECTORY" >&2
    echo "Creates host.p12, viewer.p12 and their public host.cer/viewer.cer files." >&2
}

if [[ $# -ne 1 ]]; then
    usage
    exit 2
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "${script_dir}/.." && pwd -P)"
requested_output_dir="$1"

# Resolve the existing parent before creating anything. This lets the guard
# reject repository paths without first creating an identity directory there.
output_parent="$(dirname -- "${requested_output_dir}")"
if ! output_parent="$(cd -- "${output_parent}" && pwd -P)"; then
    echo "The output directory's parent must already exist: ${requested_output_dir}" >&2
    exit 2
fi
output_dir="${output_parent}/$(basename -- "${requested_output_dir}")"

case "${output_dir}" in
    "${repo_root}"|"${repo_root}"/*)
        echo "Refusing to create identity material inside the repository: ${output_dir}" >&2
        exit 2
        ;;
esac

mkdir -p -- "${output_dir}"
output_dir="$(cd -- "${output_dir}" && pwd -P)"
case "${output_dir}" in
    "${repo_root}"|"${repo_root}"/*)
        echo "Refusing to create identity material inside the repository: ${output_dir}" >&2
        exit 2
        ;;
esac
umask 077
chmod 700 "${output_dir}"

password="${MACREMOTEAPP_P12_PASSWORD:-}"
if [[ -z "${password}" ]]; then
    read -r -s -p "PKCS#12 password (not echoed): " password
    printf '\n' >&2
    read -r -s -p "Repeat PKCS#12 password: " password_confirmation
    printf '\n' >&2
    if [[ "${password}" != "${password_confirmation}" ]]; then
        echo "Passwords do not match." >&2
        exit 1
    fi
    unset password_confirmation
fi
if [[ -z "${password}" ]]; then
    echo "The PKCS#12 password must not be empty." >&2
    exit 1
fi

work_dir="$(mktemp -d "${TMPDIR:-/private/tmp}/macremoteapp-identities.XXXXXX")"
trap 'rm -rf -- "${work_dir}"' EXIT
export MACREMOTEAPP_PKCS12_PASS="${password}"

make_identity() {
    local name="$1"
    local common_name="MacRemoteApp-${name}"

    openssl ecparam -name prime256v1 -genkey -noout \
        -out "${work_dir}/${name}.key"
    openssl req -new -x509 -sha256 \
        -key "${work_dir}/${name}.key" \
        -out "${work_dir}/${name}.crt" \
        -days 365 \
        -subj "/CN=${common_name}" \
        -addext "basicConstraints=critical,CA:FALSE" \
        -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
        -addext "extendedKeyUsage=clientAuth,serverAuth"
    openssl pkcs12 -export \
        -inkey "${work_dir}/${name}.key" \
        -in "${work_dir}/${name}.crt" \
        -out "${output_dir}/${name}.p12" \
        -name "${common_name}" \
        -passout env:MACREMOTEAPP_PKCS12_PASS
    openssl x509 \
        -in "${work_dir}/${name}.crt" \
        -outform DER \
        -out "${output_dir}/${name}.cer"
    chmod 600 "${output_dir}/${name}.p12"
    chmod 644 "${output_dir}/${name}.cer"
}

make_identity host
make_identity viewer

unset password
unset MACREMOTEAPP_PKCS12_PASS
echo "Created M2 identities in ${output_dir}"
echo "Keep host.p12 on the Intel Host and viewer.p12 on the Apple Silicon Viewer."
echo "Only copy the opposite .cer file to each device; never copy a .p12 private key."
