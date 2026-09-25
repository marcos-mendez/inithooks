#!/usr/bin/env bats
# Tests for lib/ipconfig.sh and firstboot.d/01ipconfig.
#
# The library functions are called directly; the hook is run against a
# scratch /etc/default/inithooks, preseed and interfaces file with ip, ifup,
# turnkey-version and head replaced by stubs.

load helpers

REPO=$BATS_TEST_DIRNAME/..
HOOK=$REPO/firstboot.d/01ipconfig

# a stock interfaces file, as an install ships it
STOCK_INTERFACES='# UNCONFIGURED INTERFACES
# remove the above line if you edit this file

auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
    hostname tkldev
iface eth0 inet6 dhcp
    hostname tkldev'

setup() {
    source "$REPO/lib/ipconfig.sh"
    setup_stubs
    stub ip
    stub ifup
    stub turnkey-version 'echo tkldev'
    stub_head tkldev

    export INITHOOKS_DEFAULT=$BATS_TEST_TMPDIR/default-inithooks
    export INITHOOKS_CONF=$BATS_TEST_TMPDIR/inithooks.conf
    export INTERFACES=$BATS_TEST_TMPDIR/interfaces
    cat > "$INITHOOKS_DEFAULT" <<EOT
INITHOOKS_CONF=$INITHOOKS_CONF
INITHOOKS_PATH=$REPO
EOT
    echo "$STOCK_INTERFACES" > "$INTERFACES"
}

# preseed VAR=VALUE...
# Writes the preseed file the hook sources.
preseed() {
    printf '%s\n' "$@" > "$INITHOOKS_CONF"
}

# ---------------------------------------------------------------- library

@test "valid_config accepts dhcp, manual and static" {
    ipconfig_valid_config dhcp
    ipconfig_valid_config manual
    ipconfig_valid_config static
}

@test "valid_config rejects anything else" {
    ! ipconfig_valid_config bogus
    ! ipconfig_valid_config ''
    ! ipconfig_valid_config 'static dhcp'
}

@test "iface is br0 on lxc and eth0 elsewhere" {
    [ "$(ipconfig_iface lxc)" = br0 ]
    [ "$(ipconfig_iface tkldev)" = eth0 ]
    [ "$(ipconfig_iface '')" = eth0 ]
}

@test "unchanged succeeds only when the stanza is already there" {
    ipconfig_unchanged "$INTERFACES" eth0 dhcp
    ! ipconfig_unchanged "$INTERFACES" eth0 static
    ! ipconfig_unchanged "$INTERFACES" br0 dhcp
}

@test "unchanged fails silently when the file is missing" {
    run ipconfig_unchanged "$BATS_TEST_TMPDIR/missing" eth0 dhcp
    [ "$status" -eq 2 ]
    [ -z "$output" ]
}

@test "render_head writes the confconsole header, lo and the IPv4 stanza" {
    run ipconfig_render_head eth0 manual host6
    [ "$status" -eq 0 ]
    [ "$output" = '# UNCONFIGURED INTERFACES
# remove the above line if you edit this file

auto lo
iface lo inet loopback

auto eth0
iface eth0 inet manual
    hostname host6' ]
}

@test "check_static passes when address and netmask are set" {
    run ipconfig_check_static 2001:db8:1::10 64
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "check_static names a missing address" {
    run ipconfig_check_static '' 64
    [ "$status" -eq 1 ]
    [ "$output" = 'IP_CONFIG=static requires IP_ADDRESS' ]
}

@test "check_static names a missing netmask" {
    run ipconfig_check_static 2001:db8:1::10 ''
    [ "$status" -eq 1 ]
    [ "$output" = 'IP_CONFIG=static requires IP_NETMASK' ]
}

@test "render_static with address and netmask only" {
    run ipconfig_render_static 2001:db8:1::10 64
    [ "$output" = '    address 2001:db8:1::10
    netmask 64' ]
}

@test "render_static adds the gateway when set" {
    run ipconfig_render_static 2001:db8:1::10 64 2001:db8:1::1
    [ "$output" = '    address 2001:db8:1::10
    netmask 64
    gateway 2001:db8:1::1' ]
}

@test "render_static joins both nameservers" {
    run ipconfig_render_static 2001:db8:1::10 64 2001:db8:1::1 \
        2001:db8:1::53 2001:db8:2::53
    [ "$output" = '    address 2001:db8:1::10
    netmask 64
    gateway 2001:db8:1::1
    dns-nameservers 2001:db8:1::53 2001:db8:2::53' ]
}

@test "render_static writes a single nameserver without spare spaces" {
    run ipconfig_render_static 2001:db8:1::10 64 '' '' 2001:db8:2::53
    [ "$output" = '    address 2001:db8:1::10
    netmask 64
    dns-nameservers 2001:db8:2::53' ]
}

@test "render_inet6 keeps IPv6 on" {
    run ipconfig_render_inet6 br0 host6
    [ "$output" = 'iface br0 inet6 dhcp
    hostname host6' ]
}

# ------------------------------------------------------------------- hook

@test "hook exits 0 and touches nothing without a preseed file" {
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(cat "$INTERFACES")" = "$STOCK_INTERFACES" ]
    [ -z "$(calls ip)" ]
}

@test "hook exits 0 when IP_CONFIG is empty" {
    preseed 'IP_CONFIG=' 'IP_ADDRESS=2001:db8:1::10'
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ "$(cat "$INTERFACES")" = "$STOCK_INTERFACES" ]
    [ -z "$(calls ip)" ]
}

@test "hook is fatal on an invalid IP_CONFIG" {
    preseed 'IP_CONFIG=bogus'
    run "$HOOK"
    [ "$status" -eq 1 ]
    [ "$output" = "fatal Invalid: IP_CONFIG='bogus' - valid values: manual|static|dhcp" ]
    [ "$(cat "$INTERFACES")" = "$STOCK_INTERFACES" ]
    [ -z "$(calls ip)" ]
}

@test "hook is fatal when the interfaces file is missing" {
    preseed 'IP_CONFIG=dhcp'
    rm "$INTERFACES"
    run "$HOOK"
    [ "$status" -eq 1 ]
    [ "$output" = "fatal $INTERFACES file not found" ]
    [ -z "$(calls ip)" ]
}

@test "hook short-circuits when the config is unchanged" {
    preseed 'IP_CONFIG=dhcp'
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(cat "$INTERFACES")" = "$STOCK_INTERFACES" ]
    [ -z "$(calls ip)" ]
    [ -z "$(calls ifup)" ]
}

@test "hook dhcp rewrites a manual file and brings the interface up" {
    preseed 'IP_CONFIG=dhcp'
    sed -i 's/inet dhcp/inet manual/' "$INTERFACES"
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ "$(cat "$INTERFACES")" = "$STOCK_INTERFACES" ]
    [ "$(calls ip)" = 'link set eth0 down' ]
    [ "$(calls ifup)" = '--all --exclude=lo' ]
}

@test "hook manual keeps the header and the IPv6 stanza" {
    preseed 'IP_CONFIG=manual'
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ "$(cat "$INTERFACES")" = '# UNCONFIGURED INTERFACES
# remove the above line if you edit this file

auto lo
iface lo inet loopback

auto eth0
iface eth0 inet manual
    hostname tkldev
iface eth0 inet6 dhcp
    hostname tkldev' ]
    [ "$(calls turnkey-version)" = '-n' ]
    [ "$(calls head)" = '-1 /etc/hostname' ]
}

@test "hook static writes address, netmask, gateway and nameservers" {
    preseed 'IP_CONFIG=static' 'IP_ADDRESS=2001:db8:1::10' 'IP_NETMASK=64' \
        'IP_GW=2001:db8:1::1' 'IP_DNS1=2001:db8:1::53' 'IP_DNS2=2001:db8:2::53'
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ "$(cat "$INTERFACES")" = '# UNCONFIGURED INTERFACES
# remove the above line if you edit this file

auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    hostname tkldev
    address 2001:db8:1::10
    netmask 64
    gateway 2001:db8:1::1
    dns-nameservers 2001:db8:1::53 2001:db8:2::53
iface eth0 inet6 dhcp
    hostname tkldev' ]
    [ "$(calls ifup)" = '--all --exclude=lo' ]
}

@test "hook static without gateway and dns omits those lines" {
    preseed 'IP_CONFIG=static' 'IP_ADDRESS=2001:db8:1::10' 'IP_NETMASK=64'
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ "$(cat "$INTERFACES")" = '# UNCONFIGURED INTERFACES
# remove the above line if you edit this file

auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    hostname tkldev
    address 2001:db8:1::10
    netmask 64
iface eth0 inet6 dhcp
    hostname tkldev' ]
}

@test "hook static without an address is fatal after taking the link down" {
    preseed 'IP_CONFIG=static' 'IP_NETMASK=64'
    run "$HOOK"
    [ "$status" -eq 1 ]
    [ "$output" = 'fatal IP_CONFIG=static requires IP_ADDRESS' ]
    [ "$(calls ip)" = 'link set eth0 down' ]
    [ -z "$(calls ifup)" ]
    [ "$(tail -1 "$INTERFACES")" = '    hostname tkldev' ]
    ! grep -q inet6 "$INTERFACES"
}

@test "hook static without a netmask is fatal" {
    preseed 'IP_CONFIG=static' 'IP_ADDRESS=2001:db8:1::10'
    run "$HOOK"
    [ "$status" -eq 1 ]
    [ "$output" = 'fatal IP_CONFIG=static requires IP_NETMASK' ]
    [ -z "$(calls ifup)" ]
}

@test "hook configures br0 on an lxc build" {
    preseed 'IP_CONFIG=manual'
    stub turnkey-version 'echo lxc'
    run "$HOOK"
    [ "$status" -eq 0 ]
    grep -q '^iface br0 inet manual$' "$INTERFACES"
    grep -q '^iface br0 inet6 dhcp$' "$INTERFACES"
    ! grep -q eth0 "$INTERFACES"
    [ "$(calls ip)" = 'link set br0 down' ]
}

@test "hook exits with the status of ifup" {
    preseed 'IP_CONFIG=manual'
    stub ifup 'exit 3'
    run "$HOOK"
    [ "$status" -eq 3 ]
}
