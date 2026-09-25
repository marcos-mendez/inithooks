# Parsing and rendering for firstboot.d/29tagid.
#
# Sourced by the hook and by tests/test-tagid.bats. Every function here only
# reads its arguments and prints; the hook applies the results.

# tagid_app_name TURNKEY_VERSION
# Prints the appliance name of a turnkey_version string, e.g. core for
# turnkey-core-19.0-trixie-amd64.
tagid_app_name() {
    perl -pe 's/^turnkey-//; s/-[^-]+(-[^-]+){2}$//' <<< "$1"
}

# tagid_version TURNKEY_VERSION
# Prints the version of a turnkey_version string, e.g. 19.0-trixie-amd64.
tagid_version() {
    perl -pe 's/.*-([^-]+(-[^-]+){2})$/\1/' <<< "$1"
}

# tagid_build APT_CONF_LINE
# Prints the build tags found after the version inside the parentheses of
# the apt User-Agent line (01turnkey), sorted, unique and joined with '-';
# iso when there is none.
tagid_build() {
    perl -ne 'chomp; s/.*\((.*)\).*/\1/; s/^\S+ ?//; $tags=$_ ? $_ : "iso"; system("echo $tags | xargs -n 1 | sort -u | xargs echo | sed \"s/ /-/g\"");' <<< "$1"
}

# tagid_is_tagged INDEX
# Succeeds when the fence index page already loads the initfence scripts.
tagid_is_tagged() {
    grep -q ajax.turnkeylinux.org "$1"
}

# tagid_render_scripts BUILD VERSION APP_NAME
# Prints the script tags appended to the fence index page.
tagid_render_scripts() {
    local build=$1
    local version=$2
    local app_name=$3
    cat <<EOT
<script src="https://ajax.turnkeylinux.org/initfence/$build/$version/$app_name.js" async></script>
<script src="https://ajax.turnkeylinux.org/initfence/$build/$version/$app_name.direct" async></script>
EOT
}
