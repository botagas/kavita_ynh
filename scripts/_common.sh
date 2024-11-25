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
    # Declare an array to define the options of this helper.
    local legacy_args=dsk
    local -A args_array=([d]=dest_dir= [s]=source_id= [k]=keep= [r]=full_replace=)
    local dest_dir
    local source_id
    local keep
    local full_replace
    # Manage arguments with getopts
    ynh_handle_getopts_args "$@"
    keep="${keep:-}"
    full_replace="${full_replace:-0}"

    if test -e $YNH_APP_BASEDIR/manifest.toml && cat $YNH_APP_BASEDIR/manifest.toml | toml_to_json | jq -e '.resources.sources' > /dev/null; then
        source_id="${source_id:-main}"
        local sources_json=$(cat $YNH_APP_BASEDIR/manifest.toml | toml_to_json | jq ".resources.sources[\"$source_id\"]")
        if jq -re ".url" <<< "$sources_json"; then
            local arch_prefix=""
        else
            local arch_prefix=".$YNH_ARCH"
        fi

        local src_url="https://github.com/Kareadita/Kavita/releases/download/v0.8.3.2/kavita-linux-x64.tar.gz"
        local src_sum="6d4a91cfcecd80d710fa16a750206418ea636c44fd158327509a3daf48149e08"
        local src_sumprg="sha256sum"
        local src_format="$(jq -r ".format" <<< "$sources_json" | sed 's/^null$//')"
        local src_in_subdir="$(jq -r ".in_subdir" <<< "$sources_json" | sed 's/^null$//')"
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
            elif [[ -z "$src_extract" ]]; then
                src_extract="false"
            fi
        fi
    else
        source_id="${source_id:-app}"
        local src_file_path="$YNH_APP_BASEDIR/conf/${source_id}.src"

        # Load value from configuration file (see above for a small doc about this file
        # format)
        local src_url=$(grep 'SOURCE_URL=' "$src_file_path" | cut --delimiter='=' --fields=2-)
        local src_sum=$(grep 'SOURCE_SUM=' "$src_file_path" | cut --delimiter='=' --fields=2-)
        local src_sumprg=$(grep 'SOURCE_SUM_PRG=' "$src_file_path" | cut --delimiter='=' --fields=2-)
        local src_format=$(grep 'SOURCE_FORMAT=' "$src_file_path" | cut --delimiter='=' --fields=2-)
        local src_in_subdir=$(grep 'SOURCE_IN_SUBDIR=' "$src_file_path" | cut --delimiter='=' --fields=2-)
        local src_rename=$(grep 'SOURCE_FILENAME=' "$src_file_path" | cut --delimiter='=' --fields=2-)
        local src_extract=$(grep 'SOURCE_EXTRACT=' "$src_file_path" | cut --delimiter='=' --fields=2-)
        local src_platform=$(grep 'SOURCE_PLATFORM=' "$src_file_path" | cut --delimiter='=' --fields=2-)
    fi

    # Default value
    src_sumprg=${src_sumprg:-sha256sum}
    src_in_subdir=${src_in_subdir:-true}
    src_format=${src_format:-tar.gz}
    src_format=$(echo "$src_format" | tr '[:upper:]' '[:lower:]')
    src_extract=${src_extract:-true}

    if [[ "$src_extract" != "true" ]] && [[ "$src_extract" != "false" ]]; then
        ynh_die "For source $source_id, expected either 'true' or 'false' for the extract parameter"
    fi

    # (Unused?) mecanism where one can have the file in a special local cache to not have to download it...
    local local_src="/opt/yunohost-apps-src/${YNH_APP_ID}/${source_id}"

    # Gotta use this trick with 'dirname' because source_id may contain slashes x_x
    mkdir -p $(dirname /var/cache/yunohost/download/${YNH_APP_ID}/${source_id})
    src_filename="/var/cache/yunohost/download/${YNH_APP_ID}/${source_id}"

    if [ "$src_format" = "docker" ]; then
        src_platform="${src_platform:-"linux/$YNH_ARCH"}"
    else
        if test -e "$local_src"; then
            cp $local_src $src_filename
        fi

        [ -n "$src_url" ] || ynh_die "Couldn't parse SOURCE_URL from $src_file_path ?"

        # If the file was prefetched but somehow doesn't match the sum, rm and redownload it
        if [ -e "$src_filename" ] && ! echo "${src_sum} ${src_filename}" | ${src_sumprg} --check --status; then
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
                || ynh_die --message="$out"
        fi

        # Check the control sum
        if ! echo "${src_sum} ${src_filename}" | ${src_sumprg} --check --status; then
            local actual_sum="$(${src_sumprg} ${src_filename} | cut --delimiter=' ' --fields=1)"
            local actual_size="$(du -hs ${src_filename} | cut --fields=1)"
            rm -f ${src_filename}
            ynh_die --message="Corrupt source for ${src_url}: Expected sha256sum to be ${src_sum} but got ${actual_sum} (size: ${actual_size})."
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
        ynh_secure_remove --file="$dest_dir"
    fi

    # Extract source into the app dir
    mkdir --parents "$dest_dir"

    if [ -n "${install_dir:-}" ] && [ "$dest_dir" == "$install_dir" ]; then
        _ynh_apply_default_permissions $dest_dir
    fi
    if [ -n "${final_path:-}" ] && [ "$dest_dir" == "$final_path" ]; then
        _ynh_apply_default_permissions $dest_dir
    fi

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
            ynh_secure_remove --file="$tmp_dir"
        else
            unzip -quo $src_filename -d "$dest_dir"
        fi
        ynh_secure_remove --file="$src_filename"
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
        if [[ "$src_format" =~ ^tar.gz|tar.bz2|tar.xz$ ]]; then
            tar --extract --file=$src_filename --directory="$dest_dir" $strip --no-same-owner
        else
            ynh_die --message="Archive format unrecognized."
        fi
        ynh_secure_remove --file="$src_filename"
    fi

    # Apply patches
    if [ -d "$YNH_APP_BASEDIR/sources/patches/" ]; then
        local patches_folder=$(realpath $YNH_APP_BASEDIR/sources/patches/)
        if (($(find $patches_folder -type f -name "${source_id}-*.patch" 2> /dev/null | wc --lines) > "0")); then
            pushd "$dest_dir"
            for p in $patches_folder/${source_id}-*.patch; do
                echo $p
                patch --strip=1 < $p || ynh_print_warn --message="Packagers /!\\ patch $p failed to apply"
            done
            popd
        fi
    fi

    # Add supplementary files
    if test -e "$YNH_APP_BASEDIR/sources/extra_files/${source_id}"; then
        cp --archive $YNH_APP_BASEDIR/sources/extra_files/$source_id/. "$dest_dir"
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
}
#=================================================
# EXPERIMENTAL HELPERS
#=================================================

#=================================================
# FUTURE OFFICIAL HELPERS
#=================================================
