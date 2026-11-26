#!/usr/bin/env bash

set -u
set -o pipefail

PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/usr/syno/bin"
PATH="${PATH}:/var/packages/ContainerManager/target/usr/bin"
PATH="${PATH}:/var/packages/Docker/target/usr/bin"
export PATH

SYNO_WEBAPI=${SYNO_WEBAPI:-/usr/syno/bin/synowebapi}
CERT_ARCHIVE_ROOT=${CERT_ARCHIVE_ROOT:-/usr/syno/etc/certificate/_archive}
LOCK_DIR=${LOCK_DIR:-/run/exportSynoCert.lock.d}
CADDY_CONFIG=/etc/caddy/Caddyfile
EXPIRY_WARNING_SECONDS=$((14 * 24 * 60 * 60))

cert_common_name=""
output_dir=""
id_only=0
summary_only=0
reload_proxy=0
supported_proxies=(caddy)
source_pem_files=()
stage_dir=""
lock_acquired=0

usage() {
    printf '%s\n' \
        "Usage:" \
        "  exportSynoCert.sh [-h | -s | -i]" \
        "  exportSynoCert.sh -o OUTPUT_DIR [--reload]" \
        "" \
        "Options:" \
        "  -s               Show certificate summary. No copying." \
        "  -i               Print matching certificate ID only. No copying." \
        "  -o OUTPUT_DIR    Export PEM files, fullchain.pem, and privkey.pem." \
        "  --reload         Detect, validate, and reload proxy. Requires -o." \
        "                   Without --reload, only export files." \
        "                   Supported proxy: Caddy." \
        "  -h               Show this help." \
        "" \
        "Examples:" \
        "  exportSynoCert.sh -s" \
        "  exportSynoCert.sh -i" \
        "  exportSynoCert.sh -o /volume4/docker/caddy/certs/ --reload"
}

parse_options() {
    local opt
    local arg
    local end_options=0
    local normalized_args=()

    if [ "$#" -eq 0 ]; then
        usage
        return 10
    fi

    for arg in "$@"; do
        if [ "$end_options" -eq 1 ]; then
            normalized_args+=("$arg")
            continue
        fi

        case "$arg" in
            --reload)
                normalized_args+=("-r")
                ;;
            --caddy)
                printf '%s\n' "ERROR: --caddy was removed; use --reload." >&2
                return 2
                ;;
            --)
                normalized_args+=("--")
                end_options=1
                ;;
            *)
                normalized_args+=("$arg")
                ;;
        esac
    done

    set -- "${normalized_args[@]}"
    OPTIND=1

    while getopts ":o:isrh" opt; do
        case "$opt" in
            o)
                output_dir=$OPTARG
                if [ -z "$output_dir" ]; then
                    printf '%s\n' "ERROR: -o requires a nonempty directory." >&2
                    return 2
                fi
                ;;
            s)
                summary_only=1
                ;;
            i)
                id_only=1
                ;;
            r)
                reload_proxy=1
                ;;
            h)
                usage
                return 10
                ;;
            :)
                printf 'ERROR: option -%s requires an argument.\n' \
                    "$OPTARG" >&2
                usage >&2
                return 2
                ;;
            \?)
                printf 'ERROR: unknown option: -%s\n' "$OPTARG" >&2
                usage >&2
                return 2
                ;;
        esac
    done

    shift "$((OPTIND - 1))"

    if [ "$#" -ne 0 ]; then
        printf 'ERROR: unexpected argument: %s\n' "$1" >&2
        usage >&2
        return 2
    fi

    if [ "$summary_only" -eq 1 ] &&
        { [ "$id_only" -eq 1 ] || [ -n "$output_dir" ] ||
            [ "$reload_proxy" -eq 1 ]; }; then
        printf '%s\n' \
            "ERROR: -s cannot be combined with -i, -o, or --reload." >&2
        return 2
    fi

    if [ "$id_only" -eq 1 ] && [ -n "$output_dir" ]; then
        printf '%s\n' \
            "ERROR: -i ID-only mode cannot be combined with -o." >&2
        return 2
    fi

    if [ "$id_only" -eq 1 ] && [ "$reload_proxy" -eq 1 ]; then
        printf '%s\n' \
            "ERROR: -i ID-only mode cannot be combined with --reload." >&2
        return 2
    fi

    if [ "$reload_proxy" -eq 1 ] && [ -z "$output_dir" ]; then
        printf '%s\n' \
            "ERROR: --reload requires -o OUTPUT_DIR. No default is used." >&2
        return 2
    fi

    if [ "$summary_only" -eq 0 ] && [ "$id_only" -eq 0 ] &&
        [ -z "$output_dir" ]; then
        usage
        return 10
    fi

    return 0
}

use_sudo() {
    [ "$EUID" -ne 0 ]
}

run_privileged() {
    if use_sudo; then
        sudo "$@"
    else
        "$@"
    fi
}

require_command() {
    local command_name=$1

    if command -v "$command_name" >/dev/null 2>&1; then
        return 0
    fi

    printf 'ERROR: required command was not found: %s\n' \
        "$command_name" >&2
    return 1
}

require_tools() {
    if ! require_command jq; then
        return 1
    fi

    if [ ! -x "$SYNO_WEBAPI" ]; then
        printf 'ERROR: synowebapi not found or not executable: %s\n' \
            "$SYNO_WEBAPI" >&2
        return 1
    fi

    if use_sudo; then
        if ! require_command sudo; then
            return 1
        fi
    fi

    if [ -n "$output_dir" ]; then
        require_command mkdir || return 1
        require_command rmdir || return 1
        require_command readlink || return 1
        require_command stat || return 1
        if ! require_command cmp; then
            return 1
        fi

        if ! require_command openssl; then
            return 1
        fi
    fi

    if [ "$reload_proxy" -eq 1 ]; then
        if ! require_command docker; then
            return 1
        fi
    fi

    return 0
}

cleanup_stage_dir() {
    if [ -n "$stage_dir" ]; then
        run_privileged rm -rf -- "$stage_dir" 2>/dev/null || true
        stage_dir=""
    fi
}

cleanup() {
    cleanup_stage_dir
    if [ "$lock_acquired" -eq 1 ]; then
        if ! run_privileged rmdir -- "$LOCK_DIR"; then
            print_error "could not release export lock: $LOCK_DIR"
        fi
        lock_acquired=0
    fi
}

acquire_lock() {
    # mkdir is atomic. Never remove a lock owned by another invocation.
    if ! run_privileged mkdir -m 700 -- "$LOCK_DIR" 2>/dev/null; then
        print_error "could not acquire export lock: $LOCK_DIR"
        printf '%s\n' \
            "Another export may be active, or a stale lock may remain." \
            "Remove a stale lock only after verifying no export is running." >&2
        return 1
    fi
    lock_acquired=1
    return 0
}

print_error() {
    printf 'ERROR: %s\n' "$*" >&2
}

extract_json_object() {
    awk '
        /^[[:space:]]*\{/ { json_started = 1 }
        json_started { print }
    '
}

get_webapi_json() {
    local api=$1
    local array=$2
    local raw_output
    local json_output

    if ! raw_output=$(
        run_privileged "$SYNO_WEBAPI" --exec-fastwebapi \
            api="$api" method=list version=1 2>&1
    ); then
        print_error "DSM WebAPI request failed: $api"
        return 1
    fi
    json_output=$(extract_json_object <<< "$raw_output")
    if ! jq -e --arg array "$array" '
        .success == true and (.data[$array] | type == "array")
    ' <<< "$json_output" >/dev/null 2>&1; then
        print_error "invalid or unsuccessful DSM API response: $api"
        return 1
    fi
    printf '%s\n' "$json_output"
}

get_ddns_json() {
    get_webapi_json SYNO.Core.DDNS.Record records
}

get_synology_ddns_hostname() {
    local json_output
    local hostname

    if ! json_output=$(get_ddns_json); then
        return 1
    fi

    if ! hostname=$(printf '%s\n' "$json_output" | jq -er '
        [.data.records[] | select(.provider == "Synology")]
        | select(length == 1)
        | .[0].hostname
        | select(type == "string" and test("^[A-Za-z0-9.-]+$"))
    ' 2>/dev/null) || [ -z "$hostname" ]; then
        printf '%s\n' \
            "ERROR: could not detect a unique Synology DDNS hostname." \
            "Check the Synology DDNS settings in DSM." >&2
        return 1
    fi

    printf '%s\n' "$hostname"
    return 0
}

get_certificate_json() {
    get_webapi_json SYNO.Core.Certificate.CRT certificates
}

print_available_certificates() {
    local cert_json=$1

    printf '%s\n' "Available certificates:" >&2
    printf '%s\n' "$cert_json" |
        jq -r '
            .data.certificates[]?
            | "  id=\(.id)  common_name=\(.subject.common_name // "(missing)")  desc=\(.desc // "")"
        ' >&2
}

find_matching_certificates() {
    jq --arg cn "$cert_common_name" '
        [.data.certificates[] | select(
            ((.subject.common_name // "") | ascii_downcase)
            == ($cn | ascii_downcase))]
    ' <<< "$1"
}

print_duplicate_matches() {
    printf 'ERROR: multiple certificates matched common_name: %s\n\n' \
        "$cert_common_name" >&2
    jq -r '.[] | "  id=\(.id)  common_name=\(.subject.common_name)  desc=\(.desc // "")"' \
        <<< "$1" >&2
}

print_summary() {
    local matched_cert=$1
    local archive_src=$2
    local archive_status

    if run_privileged test -d "$archive_src"; then
        archive_status="present"
    else
        archive_status="not found"
    fi

    jq -r --arg archive_src "$archive_src" \
            --arg archive_status "$archive_status" '
            "Certificate summary:"
              + "\n  Common name:       \(.subject.common_name // "")"
              + "\n  ID:                \(.id // "")"
              + "\n  Description:       \(.desc // "")"
              + "\n  Issuer:            \(.issuer.organization // "") \(.issuer.common_name // "")"
              + "\n  Default:           \(.is_default)"
              + "\n  Renewable:         \(.renewable)"
              + "\n  Valid from:        \(.valid_from // "")"
              + "\n  Valid till:        \(.valid_till // "")"
              + "\n  Archive directory: \($archive_src)"
              + "\n  Archive status:    \($archive_status)"
        ' <<< "$matched_cert" || return 1

    if [ -n "$output_dir" ]; then
        printf '  Output directory:  %s\n' "$output_dir"
    else
        printf '%s\n' "  Output directory:  none; no files copied"
    fi
}

file_ends_with_newline() {
    local file=$1
    local newline_count

    if ! run_privileged test -s "$file"; then
        return 0
    fi

    newline_count=$(run_privileged tail -c 1 "$file" 2>/dev/null | wc -l)
    [ "$newline_count" -eq 1 ]
}

enumerate_source_pems() {
    local archive_src=$1
    local file_list
    if ! file_list=$(run_privileged find "$archive_src" -maxdepth 1 \
        -type f -name '*.pem' ! -name fullchain.pem \
        ! -name privkey.pem -print | sort); then
        print_error "failed enumerating source PEM files."
        return 1
    fi
    if [ -z "$file_list" ]; then
        print_error "no source PEM files found: $archive_src"
        return 1
    fi
    mapfile -t source_pem_files <<< "$file_list"
}

validate_archive_pem_files() {
    local src_file
    for src_file in "${source_pem_files[@]}"; do
        if ! run_privileged test -s "$src_file"; then
            print_error "certificate archive contains an empty PEM: $src_file"
            return 1
        fi
    done
}

validate_rsa_keypair_sources() {
    local directory=$1
    local required_file

    for required_file in RSA-cert.pem RSA-chain.pem RSA-privkey.pem; do
        if ! run_privileged test -s "$directory/$required_file"; then
            printf 'ERROR: %s is missing or empty; export cannot continue.\n' \
                "$directory/$required_file" >&2
            return 1
        fi
    done

    return 0
}

validate_rsa_certificate_material() {
    local directory=$1
    local check_expiry=${2:-1}
    local rsa_cert="$directory/RSA-cert.pem"
    local rsa_chain="$directory/RSA-chain.pem"
    local rsa_privkey="$directory/RSA-privkey.pem"
    local cert_modulus
    local key_modulus

    if ! validate_rsa_keypair_sources "$directory"; then
        return 1
    fi

    if ! run_privileged openssl x509 -in "$rsa_cert" \
        -noout >/dev/null 2>&1; then
        printf '%s\n' "ERROR: RSA-cert.pem is not a valid X.509 certificate." >&2
        return 1
    fi

    if ! run_privileged openssl x509 -in "$rsa_chain" \
        -noout >/dev/null 2>&1; then
        printf '%s\n' "ERROR: RSA-chain.pem does not contain a valid certificate." >&2
        return 1
    fi

    if ! run_privileged openssl rsa -in "$rsa_privkey" \
        -check -noout >/dev/null 2>&1; then
        printf '%s\n' "ERROR: RSA-privkey.pem is not a valid RSA private key." >&2
        return 1
    fi

    cert_modulus=$(run_privileged openssl x509 -in "$rsa_cert" \
        -noout -modulus 2>/dev/null) || return 1
    key_modulus=$(run_privileged openssl rsa -in "$rsa_privkey" \
        -noout -modulus 2>/dev/null) || return 1

    if [ "$cert_modulus" != "$key_modulus" ]; then
        printf '%s\n' \
            "ERROR: RSA-cert.pem does not match RSA-privkey.pem." >&2
        return 1
    fi

    if ! run_privileged openssl crl2pkcs7 -nocrl -certfile "$rsa_chain" \
        -out /dev/null >/dev/null 2>&1 ||
        ! run_privileged openssl verify -partial_chain -trusted "$rsa_chain" \
            "$rsa_cert" >/dev/null 2>&1; then
        print_error "RSA certificate chain validation failed."
        return 1
    fi

    if [ "$check_expiry" -eq 1 ]; then
        if ! run_privileged openssl x509 -in "$rsa_cert" \
            -checkend 0 -noout >/dev/null 2>&1; then
            printf '%s\n' "ERROR: RSA-cert.pem is already expired." >&2
            return 1
        fi

        if ! run_privileged openssl x509 -in "$rsa_cert" \
            -checkend "$EXPIRY_WARNING_SECONDS" \
            -noout >/dev/null 2>&1; then
            printf '%s\n' \
                "WARNING: RSA-cert.pem expires within 14 days." >&2
        fi
    fi

    return 0
}

generate_fullchain() {
    local directory=$1
    run_privileged cat "$directory/RSA-cert.pem" || return 1
    if ! file_ends_with_newline "$directory/RSA-cert.pem"; then
        printf '\n'
    fi
    run_privileged cat "$directory/RSA-chain.pem"
}

build_fullchain_file() {
    if ! generate_fullchain "$1" | run_privileged tee "$2" >/dev/null; then
        print_error "failed generating fullchain: $2"
        return 1
    fi
}

fullchain_matches_rsa_source() {
    generate_fullchain "$1" |
        run_privileged cmp - "$output_dir/fullchain.pem" >/dev/null 2>&1
}

certificate_export_is_current() {
    local archive_src=$1
    local src_file
    local base_name

    for src_file in "${source_pem_files[@]}"; do
        base_name=${src_file##*/}
        if ! run_privileged test -f "$output_dir/$base_name"; then
            return 1
        fi

        if ! run_privileged cmp "$src_file" "$output_dir/$base_name" \
            >/dev/null 2>&1; then
            return 1
        fi
    done

    if ! fullchain_matches_rsa_source "$archive_src"; then
        return 1
    fi

    if ! run_privileged test -f "$output_dir/privkey.pem"; then
        return 1
    fi

    if ! run_privileged cmp "$archive_src/RSA-privkey.pem" \
        "$output_dir/privkey.pem" >/dev/null 2>&1; then
        return 1
    fi

    return 0
}

set_managed_pem_permissions() {
    local target_dir=$1
    local src_file base_name
    local -a public_files=() private_files=()
    for src_file in "${source_pem_files[@]}" fullchain.pem privkey.pem; do
        base_name=${src_file##*/}
        case "$base_name" in
            *cert.pem|*chain.pem) public_files+=("$target_dir/$base_name") ;;
            *) private_files+=("$target_dir/$base_name") ;;
        esac
    done
    run_privileged chmod 644 -- "${public_files[@]}" || return 1
    run_privileged chmod 600 -- "${private_files[@]}" || return 1
}

copy_source_pems_to_stage() {
    local archive_src=$1
    local src_file
    local base_name
    local copied=0

    for src_file in "${source_pem_files[@]}"; do
        base_name=${src_file##*/}
        if ! run_privileged cp -p "$src_file" "$stage_dir/$base_name"; then
            printf 'ERROR: failed staging %s\n' "$base_name" >&2
            return 1
        fi

        copied=$((copied + 1))
    done

    if [ "$copied" -eq 0 ]; then
        printf 'ERROR: no PEM files were staged from: %s\n' \
            "$archive_src" >&2
        return 1
    fi

    printf '%s\n' "$copied"
    return 0
}

create_keypair_in_stage() {
    if ! build_fullchain_file "$stage_dir" "$stage_dir/fullchain.pem"; then
        return 1
    fi

    if ! run_privileged cp -p "$stage_dir/RSA-privkey.pem" \
        "$stage_dir/privkey.pem"; then
        printf '%s\n' "ERROR: failed staging privkey.pem." >&2
        return 1
    fi

    return 0
}

validate_staged_export() {
    if ! validate_rsa_certificate_material "$stage_dir" 0; then
        return 1
    fi

    if ! run_privileged openssl crl2pkcs7 -nocrl -certfile "$stage_dir/fullchain.pem" \
        -out /dev/null >/dev/null 2>&1; then
        printf '%s\n' "ERROR: staged fullchain.pem is not valid PEM." >&2
        return 1
    fi

    return 0
}

publish_staged_export() {
    local src_file
    local base_name

    for src_file in "${source_pem_files[@]}"; do
        base_name=${src_file##*/}
        if ! run_privileged mv -f "$stage_dir/$base_name" \
            "$output_dir/$base_name"; then
            printf 'ERROR: failed publishing %s\n' "$base_name" >&2
            return 1
        fi
    done

    if ! run_privileged mv -f "$stage_dir/fullchain.pem" \
        "$output_dir/fullchain.pem"; then
        printf '%s\n' "ERROR: failed publishing fullchain.pem." >&2
        return 1
    fi

    if ! run_privileged mv -f "$stage_dir/privkey.pem" \
        "$output_dir/privkey.pem"; then
        printf '%s\n' "ERROR: failed publishing privkey.pem." >&2
        return 1
    fi

    return 0
}

realpath_dir() {
    local path=$1
    local readlink_cmd
    local resolved_path

    if ! run_privileged test -d "$path"; then
        return 1
    fi

    if ! use_sudo; then
        (
            cd -- "$path" 2>/dev/null &&
                pwd -P
        )
        return
    fi

    if readlink_cmd=$(command -v readlink 2>/dev/null); then
        resolved_path=$(
            run_privileged "$readlink_cmd" -f "$path" 2>/dev/null
        ) || resolved_path=""

        if [ -n "$resolved_path" ] &&
            run_privileged test -d "$resolved_path"; then
            printf '%s\n' "$resolved_path"
            return 0
        fi
    fi

    printf '%s\n' \
        "ERROR: could not resolve the physical output path while using sudo." \
        "Run this script as root, as recommended for DSM Task Scheduler." >&2
    return 1
}

# Proxy adapters: register a type in supported_proxies and add its
# identification, validation, reload, and display-name cases below.
proxy_display_name() {
    case "$1" in
        caddy) printf '%s\n' "Caddy" ;;
        *) return 1 ;;
    esac
}

probe_proxy_container() {
    local proxy=$1
    local container=$2

    case "$proxy" in
        caddy)
            run_privileged docker exec "$container" caddy version
            ;;
        *) return 1 ;;
    esac
}

run_proxy_action() {
    local proxy=$1
    local action=$2
    local container=$3

    case "$proxy:$action" in
        caddy:validate)
            run_privileged docker exec "$container" \
                caddy validate --config "$CADDY_CONFIG" --adapter caddyfile
            ;;
        caddy:reload)
            run_privileged docker exec "$container" \
                caddy reload --config "$CADDY_CONFIG" \
                --adapter caddyfile --force
            ;;
        *)
            print_error "unsupported proxy action: $proxy:$action"
            return 1
            ;;
    esac
}

find_proxy_containers_for_output_dir() {
    local real_output=$1
    local ids inspect_json candidates name image mount_match proxy
    local -a container_ids=()

    if ! ids=$(run_privileged docker ps -q); then
        print_error "failed listing running Docker containers."
        return 1
    fi
    [ -n "$ids" ] || return 0
    mapfile -t container_ids <<< "$ids"
    if ! inspect_json=$(run_privileged docker inspect "${container_ids[@]}"); then
        print_error "failed inspecting Docker containers."
        return 1
    fi

    candidates=$(jq -r --arg out "$real_output" '
        .[] | . as $container
        | [ .Mounts[]? | select(.Source != null)
            | (.Source | rtrimstr("/")) as $src
            | select($out == $src or ($out | startswith($src + "/")))
            | "\($src) -> \(.Destination)" ]
        | select(length > 0)
        | [($container.Name | sub("^/"; "")),
            $container.Config.Image, .[0]] | @tsv
    ' <<< "$inspect_json") || return 1
    [ -n "$candidates" ] || return 0

    while IFS=$'\t' read -r name image mount_match; do
        for proxy in "${supported_proxies[@]}"; do
            if probe_proxy_container "$proxy" "$name" >/dev/null 2>&1; then
                printf '%s\t%s\t%s\t%s\n' \
                    "$proxy" "$name" "$image" "$mount_match"
            fi
        done
    done <<< "$candidates"
    return 0
}

get_matching_proxy_container() {
    local candidates
    local -a matches=()

    # prepare_export has already normalized output_dir.
    candidates=$(find_proxy_containers_for_output_dir "$output_dir") ||
        return 1

    if [ -z "$candidates" ]; then
        print_error "no matching supported proxy container found."
        printf 'Resolved output directory: %s\n' "$output_dir" >&2
        return 1
    fi

    mapfile -t matches <<< "$candidates"
    if [ "${#matches[@]}" -ne 1 ]; then
        print_error "multiple matching proxy candidates; refusing to guess."
        printf '%s\n' "$candidates" |
            awk -F '\t' '{ printf "  type=%s  name=%s  image=%s  mount=%s\n",
                $1, $2, $3, $4 }' >&2
        return 1
    fi

    printf '%s\n' "${matches[0]}"
}

report_proxy_action() {
    local proxy=$1
    local action=$2
    local container=$3
    local label=$4
    local diagnostic

    if ! diagnostic=$(run_proxy_action "$proxy" "$action" "$container" 2>&1); then
        print_error "$label failed inside container: $container"
        if [ -n "$diagnostic" ]; then
            printf '%s\n' "$diagnostic" >&2
        fi
        return 1
    fi

    printf '%-25s%s\n' "$label:" "successful"
}

validate_and_reload_proxy() {
    local candidate proxy container_name container_image mount_match display

    candidate=$(get_matching_proxy_container) || return 1
    IFS=$'\t' read -r proxy container_name container_image mount_match \
        <<< "$candidate"
    display=$(proxy_display_name "$proxy") || return 1

    printf '%-25s%s\n' "$display container:" "$container_name"
    printf '%-25s%s\n' "$display image:" "$container_image"
    printf '%-25s%s\n' "$display cert mount:" "$mount_match"

    report_proxy_action "$proxy" validate "$container_name" \
        "$display validation" || return 1
    report_proxy_action "$proxy" reload "$container_name" \
        "$display reload"
}

validate_output_directory() {
    local candidate=$output_dir
    local resolved archive_root src_file base_name
    # Resolve existing ancestors before creating any directories.
    while ! run_privileged test -d "$candidate"; do
        if run_privileged test -e "$candidate" ||
            run_privileged test -L "$candidate"; then
            print_error "invalid output path: $candidate"
            return 1
        fi
        candidate=$(dirname -- "$candidate") || return 1
    done
    resolved=$(realpath_dir "$candidate") || return 1
    archive_root=$(realpath_dir "$CERT_ARCHIVE_ROOT") || return 1
    case "$resolved" in
        "$archive_root"|"$archive_root"/*|/usr/syno/etc/certificate|/usr/syno/etc/certificate/*)
            print_error "output directory is inside DSM certificate storage."
            return 1 ;;
    esac
    run_privileged mkdir -p -- "$output_dir" || return 1
    resolved=$(realpath_dir "$output_dir") || return 1
    case "$resolved" in
        /|"$archive_root"|"$archive_root"/*|/usr/syno/etc/certificate|/usr/syno/etc/certificate/*)
            print_error "unsafe output directory: $resolved"
            return 1 ;;
    esac
    # Reject group/world writable destinations (POSIX mode bits).
    local permissions
    permissions=$(run_privileged stat -c %a -- "$resolved") || return 1
    if [[ ! "$permissions" =~ ^[0-7]{3,4}$ ]] ||
        (( (8#$permissions & 022) != 0 )); then
        print_error "output directory must not be group/world writable: $resolved"
        return 1
    fi
    output_dir=$resolved
    for src_file in "${source_pem_files[@]}" fullchain.pem privkey.pem; do
        base_name=${src_file##*/}
        if run_privileged test -L "$output_dir/$base_name" ||
            { run_privileged test -e "$output_dir/$base_name" &&
                ! run_privileged test -f "$output_dir/$base_name"; }; then
            print_error "unsafe destination file: $output_dir/$base_name"
            return 1
        fi
    done
}

prepare_export() {
    local archive_src=$1

    if [ -z "$output_dir" ]; then
        printf '%s\n' \
            "ERROR: internal error: output_dir is empty in copy mode." >&2
        return 1
    fi

    if ! run_privileged test -d "$archive_src"; then
        printf 'ERROR: certificate archive directory not found: %s\n' \
            "$archive_src" >&2
        return 1
    fi

    enumerate_source_pems "$archive_src" || return 1
    validate_output_directory || return 1
}

copy_certificate_files() {
    local archive_src=$1
    local copied

    if ! validate_archive_pem_files "$archive_src"; then
        return 1
    fi

    if ! validate_rsa_certificate_material "$archive_src"; then
        return 1
    fi

    if certificate_export_is_current "$archive_src"; then
        if ! set_managed_pem_permissions "$output_dir"; then
            return 1
        fi

        printf '%s\n' \
            "Certificate export:       unchanged; no files copied"
        return 0
    fi

    if ! stage_dir=$(run_privileged mktemp -d \
        "$output_dir/.exportSynoCert.stage.XXXXXX"); then
        printf 'ERROR: could not create staging directory under: %s\n' \
            "$output_dir" >&2
        stage_dir=""
        return 1
    fi

    if ! copied=$(copy_source_pems_to_stage "$archive_src"); then
        return 1
    fi

    if ! create_keypair_in_stage; then
        return 1
    fi

    if ! set_managed_pem_permissions "$stage_dir"; then
        return 1
    fi

    if ! validate_staged_export; then
        return 1
    fi

    if ! publish_staged_export; then
        return 1
    fi

    cleanup_stage_dir

    printf 'PEM files copied:        %s\n' "$copied"
    printf '%s\n' \
        "Compatibility keypair:   fullchain.pem and privkey.pem generated"

    return 0
}

main() {
    local parse_status
    local cert_json
    local matching_certs matched_cert
    local match_count
    local cert_id
    local archive_src

    parse_options "$@"
    parse_status=$?

    if [ "$parse_status" -eq 10 ]; then
        return 0
    fi

    if [ "$parse_status" -ne 0 ]; then
        return "$parse_status"
    fi

    if ! require_tools; then
        return 1
    fi

    if ! cert_common_name=$(get_synology_ddns_hostname); then
        return 1
    fi

    if [ -n "$output_dir" ]; then
        trap cleanup EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        if ! acquire_lock; then
            return 1
        fi
    fi

    if ! cert_json=$(get_certificate_json); then
        return 1
    fi

    matching_certs=$(find_matching_certificates "$cert_json") || return 1
    match_count=$(jq -er 'length' <<< "$matching_certs") || return 1

    if [ "$match_count" -eq 0 ]; then
        printf 'ERROR: no certificate matched common_name: %s\n\n' \
            "$cert_common_name" >&2
        print_available_certificates "$cert_json"
        return 1
    fi

    if [ "$match_count" -gt 1 ]; then
        print_duplicate_matches "$matching_certs"
        return 1
    fi

    matched_cert=$(jq -e '.[0]' <<< "$matching_certs") || return 1
    cert_id=$(jq -er '.id | select(type == "string" and
        test("^[A-Za-z0-9_-]+$"))' <<< "$matched_cert") || {
        print_error "invalid certificate ID."
        return 1
    }
    archive_src="$CERT_ARCHIVE_ROOT/$cert_id"

    if [ "$id_only" -eq 1 ]; then
        printf '%s\n' "$cert_id"
        return 0
    fi

    if [ -n "$output_dir" ]; then
        prepare_export "$archive_src" || return 1
    fi

    print_summary "$matched_cert" "$archive_src" || return 1

    if [ -z "$output_dir" ]; then
        return 0
    fi

    if ! copy_certificate_files "$archive_src"; then
        return 1
    fi

    if [ "$reload_proxy" -eq 1 ]; then
        if ! validate_and_reload_proxy; then
            return 1
        fi
    fi

    return 0
}

main "$@"
