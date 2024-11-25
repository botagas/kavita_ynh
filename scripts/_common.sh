#!/bin/bash

#=================================================
# COMMON VARIABLES
#=================================================
# PHP APP SPECIFIC
#=================================================

#=================================================
# PERSONAL HELPERS
#=================================================
ynh_setup_source2() {
    # ============ Argument parsing =============
    echo "DEBUG: Using modified ynh_setup_source" >&2
    local -A args_array=([d]=dest_dir= [s]=source_id= [k]=keep= [r]=full_replace)
    local dest_dir
    local source_id
    local keep
    local full_replace
    ynh_handle_getopts_args "$@"
    keep="${keep:-}"
    full_replace="${full_replace:-0}"
    source_id="${source_id:-main}"
    # ===========================================

    local sources_json=$(ynh_read_manifest "resources.sources[\"$source_id\"]")
    if jq -re ".url" <<< "$sources_json"; then
        local arch_prefix=""
    else
        local arch_prefix=".$YNH_ARCH"
    fi

    local src_url="$(jq -r "$arch_prefix.url" <<< "$sources_json" | sed 's/^null$//')"
    local src_sum="$(jq -r "$arch_prefix.sha256" <<< "$sources_json" | sed 's/^null$//')"
    local src_format="$(jq -r ".format" <<< "$sources_json" | sed 's/^null$//')"
    local src_in_subdir="$(jq -r ".in_subdir" <<< "$sources_json" | sed 's/^null$//')"
    src_in_subdir=${src_in_subdir:-true}
    local src_extract="$(jq -r ".extract" <<< "$sources_json" | sed 's/^null$//')"
    local src_platform="$(jq -r ".platform" <<< "$sources_json" | sed 's/^null$//')"
    local src_rename="$(jq -r ".rename" <<< "$sources_json" | sed 's/^null$//')"

    [[ -n "$src_url" ]] || ynh_die "No URL defined for source $source_id$arch_prefix ?"
    [[ -n "$src_sum" ]] || ynh_die "No sha256 sum defined for source $source_id$arch_prefix ?"

    if [[ -z "$src_format" ]]; then
        if [[ "$src_url" =~ ^.*\.zip$ ]] || [[ "$src_url" =~ ^.*/zipball/.*$ ]]; then
            src_format="zip"
        elif [[ "$src_url" =~ ^.*\.tar\.gz$ ]] || [[ "$src_url" =~ ^.*\.tgz$ ]] || [[ "$src_url" =~ ^.*/tar\.gz/.*$ ]] || [[ "$src_url" =~ ^.*/tarball/.*$ ]]; then
            src_format="tar.gz"
        elif [[ "$src_url" =~ ^.*\.tar\.xz$ ]]; then
            src_format="tar.xz"
        elif [[ "$src_url" =~ ^.*\.tar\.bz2$ ]]; then
            src_format="tar.bz2"
        elif [[ "$src_url" =~ ^.*\.tar$ ]]; then
            src_format="tar"
        elif [[ -z "$src_extract" ]]; then
            src_extract="false"
        fi
    fi

    src_format=${src_format:-tar.gz}
    src_format=$(echo "$src_format" | tr '[:upper:]' '[:lower:]')
    src_extract=${src_extract:-true}

    if [[ "$src_extract" != "true" ]] && [[ "$src_extract" != "false" ]]; then
        ynh_die "For source $source_id, expected either 'true' or 'false' for the extract parameter"
    fi

    # Gotta use this trick with 'dirname' because source_id may contain slashes x_x
    mkdir -p $(dirname /var/cache/yunohost/download/${YNH_APP_ID}/${source_id})
    src_filename="/var/cache/yunohost/download/${YNH_APP_ID}/${source_id}"

    if [ "$src_format" = "docker" ]; then
        src_platform="${src_platform:-"linux/$YNH_ARCH"}"
    else
        [ -n "$src_url" ] || ynh_die "Couldn't parse SOURCE_URL from $src_file_path ?"

        # If the file was prefetched but somehow doesn't match the sum, rm and redownload it
        if [ -e "$src_filename" ] && ! echo "${src_sum} ${src_filename}" | sha256sum --check --status; then
            rm -f "$src_filename"
        fi

        # Only redownload the file if it wasnt prefetched
        if [ ! -e "$src_filename" ]; then
            # NB. we have to declare the var as local first,
            # otherwise 'local foo=$(false) || echo 'pwet'" does'nt work
            # because local always return 0 ...
            local out
            # Timeout option is here to enforce the timeout on dns query and tcp connect (c.f. man wget)
            out=$(wget --tries 3 --no-dns-cache --timeout 900 --no-verbose --output-document=$src_filename $src_url 2>&1) \
                || ynh_die "$out"
        fi

        # Check the control sum
        if ! echo "${src_sum} ${src_filename}" | sha256sum --check --status; then
            local actual_sum="$(sha256sum ${src_filename} | cut --delimiter=' ' --fields=1)"
            local actual_size="$(du -hs ${src_filename} | cut --fields=1)"
            rm -f ${src_filename}
            ynh_die "Corrupt source for ${src_url}: Expected sha256sum to be ${src_sum} but got ${actual_sum} (size: ${actual_size})."
        fi
    fi

    # Keep files to be backup/restored at the end of the helper
    # Assuming $dest_dir already exists
    rm -rf /var/cache/yunohost/files_to_keep_during_setup_source/
    if [ -n "$keep" ] && [ -e "$dest_dir" ]; then
        local keep_dir=/var/cache/yunohost/files_to_keep_during_setup_source/${YNH_APP_ID}
        mkdir -p $keep_dir
        local stuff_to_keep
        for stuff_to_keep in $keep; do
            if [ -e "$dest_dir/$stuff_to_keep" ]; then
                mkdir --parents "$(dirname "$keep_dir/$stuff_to_keep")"
                cp --archive "$dest_dir/$stuff_to_keep" "$keep_dir/$stuff_to_keep"
            fi
        done
    fi

    if [ "$full_replace" -eq 1 ]; then
        ynh_safe_rm "$dest_dir"
    fi

    # Extract source into the app dir
    mkdir --parents "$dest_dir"

    if [[ "$src_extract" == "false" ]]; then
        if [[ -z "$src_rename" ]]; then
            mv $src_filename $dest_dir
        else
            mv $src_filename $dest_dir/$src_rename
        fi
    elif [[ "$src_format" == "docker" ]]; then
        "$YNH_HELPERS_DIR/vendor/docker-image-extract/docker-image-extract" -p $src_platform -o $dest_dir $src_url 2>&1
    elif [[ "$src_format" == "zip" ]]; then
        # Zip format
        # Using of a temp directory, because unzip doesn't manage --strip-components
        if $src_in_subdir; then
            local tmp_dir=$(mktemp --directory)
            unzip -quo $src_filename -d "$tmp_dir"
            cp --archive $tmp_dir/*/. "$dest_dir"
            ynh_safe_rm "$tmp_dir"
        else
            unzip -quo $src_filename -d "$dest_dir"
        fi
        ynh_safe_rm "$src_filename"
    else
        local strip=""
        if [ "$src_in_subdir" != "false" ]; then
            if [ "$src_in_subdir" == "true" ]; then
                local sub_dirs=1
            else
                local sub_dirs="$src_in_subdir"
            fi
            strip="--strip-components $sub_dirs"
        fi
        if [[ "$src_format" =~ ^tar.gz|tar.bz2|tar.xz|tar$ ]]; then
            tar --extract --file=$src_filename --directory="$dest_dir" $strip --no-same-owner
        else
            ynh_die "Archive format unrecognized."
        fi
        ynh_safe_rm "$src_filename"
    fi

    # Apply patches
    if [ -d "$YNH_APP_BASEDIR/patches/" ]; then
        local patches_folder=$(realpath "$YNH_APP_BASEDIR/patches/$source_id")
        pushd "$dest_dir"
        for patchfile in "$patches_folder/"*.patch; do
            echo "Applying $patchfile"
            if ! patch --strip=1 < "$patchfile"; then
                if ynh_in_ci_tests; then
                    ynh_die "Patch $patchfile failed to apply!"
                else
                    ynh_print_warn "Warn your packagers /!\\ Patch $patchfile failed to apply"
                fi
            fi
        done
        popd
    fi

    # Keep files to be backup/restored at the end of the helper
    # Assuming $dest_dir already exists
    if [ -n "$keep" ]; then
        local keep_dir=/var/cache/yunohost/files_to_keep_during_setup_source/${YNH_APP_ID}
        local stuff_to_keep
        for stuff_to_keep in $keep; do
            if [ -e "$keep_dir/$stuff_to_keep" ]; then
                mkdir --parents "$(dirname "$dest_dir/$stuff_to_keep")"

                # We add "--no-target-directory" (short option is -T) to handle the special case
                # when we "keep" a folder, but then the new setup already contains the same dir (but possibly empty)
                # in which case a regular "cp" will create a copy of the directory inside the directory ...
                # resulting in something like /var/www/$app/data/data instead of /var/www/$app/data
                # cf https://unix.stackexchange.com/q/94831 for a more elaborate explanation on the option
                cp --archive --no-target-directory "$keep_dir/$stuff_to_keep" "$dest_dir/$stuff_to_keep"
            fi
        done
    fi
    rm -rf /var/cache/yunohost/files_to_keep_during_setup_source/

    if [ -n "${install_dir:-}" ] && [ "$dest_dir" == "$install_dir" ]; then
        _ynh_apply_default_permissions $dest_dir
    fi
}
#=================================================
# EXPERIMENTAL HELPERS
#=================================================

#=================================================
# FUTURE OFFICIAL HELPERS
#=================================================
