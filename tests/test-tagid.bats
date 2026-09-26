#!/usr/bin/env bats
# Tests for lib/tagid.sh and firstboot.d/29tagid.
#
# The library functions are called directly; the hook is run against scratch
# copies of /etc/turnkey_version, /etc/apt/apt.conf.d/01turnkey,
# /etc/default/turnkey-init-fence and the fence htdocs, with systemctl
# replaced by a stub.

load helpers

REPO=$BATS_TEST_DIRNAME/..
HOOK=$REPO/firstboot.d/29tagid
TKL_VERSION=turnkey-core-19.0-trixie-amd64
APT_LINE='Acquire::http::User-Agent "TurnKey APT-HTTP/1.3 (turnkey-core-19.0-trixie-amd64)";'
SCRIPTS='<script src="https://ajax.turnkeylinux.org/initfence/iso/19.0-trixie-amd64/core.js" async></script>
<script src="https://ajax.turnkeylinux.org/initfence/iso/19.0-trixie-amd64/core.direct" async></script>'

setup() {
    source "$REPO/lib/tagid.sh"
    setup_stubs
    # the fence is inactive unless a test says otherwise
    stub systemctl '[[ "$1" == is-active ]] && exit 3
exit 0'

    # a scratch /usr/lib/inithooks with the packaged htdocs and the library
    export INITHOOKS_PATH=$BATS_TEST_TMPDIR/inithooks
    mkdir -p "$INITHOOKS_PATH/turnkey-init-fence/htdocs"
    ln -s "$REPO/lib" "$INITHOOKS_PATH/lib"
    cp "$REPO/turnkey-init-fence/htdocs/index.html" \
        "$INITHOOKS_PATH/turnkey-init-fence/htdocs/index.html"

    export HTDOCS=$BATS_TEST_TMPDIR/var/turnkey-init-fence/htdocs
    export INITFENCE_DEFAULT=$BATS_TEST_TMPDIR/default-turnkey-init-fence
    echo "HTDOCS=$HTDOCS" > "$INITFENCE_DEFAULT"

    export TURNKEY_VERSION_FILE=$BATS_TEST_TMPDIR/turnkey_version
    export APT_CONF_TURNKEY=$BATS_TEST_TMPDIR/01turnkey
    echo "$TKL_VERSION" > "$TURNKEY_VERSION_FILE"
    echo "$APT_LINE" > "$APT_CONF_TURNKEY"
}

# ---------------------------------------------------------------- library

@test "app_name strips the turnkey prefix and the version" {
    [ "$(tagid_app_name turnkey-core-19.0-trixie-amd64)" = core ]
    [ "$(tagid_app_name turnkey-wordpress-19.0-trixie-amd64)" = wordpress ]
    [ "$(tagid_app_name turnkey-gitea-19.1-trixie-arm64)" = gitea ]
}

@test "version keeps the last three dash separated fields" {
    [ "$(tagid_version turnkey-core-19.0-trixie-amd64)" = 19.0-trixie-amd64 ]
    [ "$(tagid_version turnkey-gitea-19.1-trixie-arm64)" = 19.1-trixie-arm64 ]
}

@test "build is iso when the user agent has no tags" {
    [ "$(tagid_build "$APT_LINE")" = iso ]
}

@test "build joins the tags sorted and unique" {
    local line='Acquire::http::User-Agent "TurnKey APT-HTTP/1.3 (turnkey-core-19.0-trixie-amd64 proxmox lxc lxc)";'
    [ "$(tagid_build "$line")" = lxc-proxmox ]
}

@test "is_tagged looks for the ajax host" {
    echo '<html><body>fence</body></html>' > "$BATS_TEST_TMPDIR/index.html"
    ! tagid_is_tagged "$BATS_TEST_TMPDIR/index.html"
    echo "$SCRIPTS" >> "$BATS_TEST_TMPDIR/index.html"
    tagid_is_tagged "$BATS_TEST_TMPDIR/index.html"
}

@test "render_scripts prints the two script tags" {
    run tagid_render_scripts iso 19.0-trixie-amd64 core
    [ "$status" -eq 0 ]
    [ "$output" = "$SCRIPTS" ]
}

# ------------------------------------------------------------------- hook

@test "hook does nothing under turnkey-init" {
    _TURNKEY_INIT=1 run "$HOOK"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -e "$HTDOCS" ]
    [ -z "$(calls systemctl)" ]
}

@test "hook copies the packaged htdocs when the writable copy is missing" {
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ -f "$HTDOCS/index.html" ]
    ! grep -q '@APP_NAME@' "$HTDOCS/index.html"
    grep -q 'core' "$HTDOCS/index.html"
    [ "$(tail -2 "$HTDOCS/index.html")" = "$SCRIPTS" ]
    # the packaged copy is left as shipped
    grep -q '@APP_NAME@' "$INITHOOKS_PATH/turnkey-init-fence/htdocs/index.html"
}

@test "hook tags an existing writable index" {
    mkdir -p "$HTDOCS"
    echo '<title>@APP_NAME@</title>' > "$HTDOCS/index.html"
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ "$(cat "$HTDOCS/index.html")" = "<title>core</title>
$SCRIPTS" ]
}

@test "hook does not append the scripts twice" {
    mkdir -p "$HTDOCS"
    printf '<title>core</title>\n%s\n' "$SCRIPTS" > "$HTDOCS/index.html"
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ "$(grep -c ajax.turnkeylinux.org "$HTDOCS/index.html")" -eq 2 ]
}

@test "hook uses the build tags in the script urls" {
    echo 'Acquire::http::User-Agent "TurnKey APT-HTTP/1.3 (turnkey-core-19.0-trixie-amd64 lxc)";' \
        > "$APT_CONF_TURNKEY"
    run "$HOOK"
    [ "$status" -eq 0 ]
    grep -q 'initfence/lxc/19.0-trixie-amd64/core.js' "$HTDOCS/index.html"
}

@test "hook exits 0 without reloading an inactive fence" {
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ "$(calls systemctl)" = 'is-active --quiet turnkey-init-fence' ]
}

@test "hook reloads the fence when it is active" {
    stub systemctl 'exit 0'
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ "$(calls systemctl)" = 'is-active --quiet turnkey-init-fence
reload turnkey-init-fence' ]
}

@test "hook exits with the status of a failed reload" {
    stub systemctl '[[ "$1" == reload ]] && exit 1
exit 0'
    run "$HOOK"
    [ "$status" -eq 1 ]
}
