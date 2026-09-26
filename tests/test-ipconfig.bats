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

# ------------------------------------------------------------- library, IPv6

@test "unchanged also checks the inet6 stanza when a config is given" {
    ipconfig_unchanged "$INTERFACES" eth0 dhcp dhcp
    ! ipconfig_unchanged "$INTERFACES" eth0 dhcp static
    sed -i 's/inet dhcp/inet manual/' "$INTERFACES"
    ! ipconfig_unchanged "$INTERFACES" eth0 dhcp dhcp
}

@test "ip6_syntax accepts full, compressed and edge addresses" {
    ipconfig_ip6_syntax 2001:db8:1::10
    ipconfig_ip6_syntax 2001:0db8:0001:0000:0000:0000:0000:0010
    ipconfig_ip6_syntax fe80::1
    ipconfig_ip6_syntax ::
    ipconfig_ip6_syntax ::1
    ipconfig_ip6_syntax 1::
    ipconfig_ip6_syntax 2001:db8:1:2:3:4:5::
    ipconfig_ip6_syntax ABCD:EF01::2
}

@test "ip6_syntax rejects what is not an IPv6 address" {
    ! ipconfig_ip6_syntax ''
    ! ipconfig_ip6_syntax 2001
    ! ipconfig_ip6_syntax 192.0.2.10
    ! ipconfig_ip6_syntax 2001:db8:1::10/64
    ! ipconfig_ip6_syntax 2001:db8:1:::10
    ! ipconfig_ip6_syntax 2001::db8::10
    ! ipconfig_ip6_syntax :2001:db8:1:2:3:4:5:6
    ! ipconfig_ip6_syntax 2001:db8:1:2:3:4:5:6:
    ! ipconfig_ip6_syntax 12345::1
    ! ipconfig_ip6_syntax 2001:db8:g::1
    ! ipconfig_ip6_syntax 1:2:3:4:5:6:7
    ! ipconfig_ip6_syntax 1:2:3:4:5:6:7:8:9
    ! ipconfig_ip6_syntax 1:2:3:4:5:6:7::8
}

@test "ip6_first_group pads and lowercases the first group" {
    [ "$(ipconfig_ip6_first_group 2001:db8::1)" = 2001 ]
    [ "$(ipconfig_ip6_first_group FE80::1)" = fe80 ]
    [ "$(ipconfig_ip6_first_group 1::)" = 0001 ]
    [ "$(ipconfig_ip6_first_group ::1)" = 0000 ]
}

@test "check_ip6 accepts global and link-local unicast" {
    ipconfig_check_ip6 2001:db8:1::10 IP6_GW
    ipconfig_check_ip6 fe80::1 IP6_GW
    ipconfig_check_ip6 ::10 IP6_GW
    [ -z "$(ipconfig_check_ip6 fe80::1 IP6_GW)" ]
}

@test "check_ip6 refuses a prefix length" {
    run ipconfig_check_ip6 2001:db8:1::1/64 IP6_GW
    [ "$status" -eq 1 ]
    [ "$output" = "IP6_GW must be a plain address, not address/prefix: '2001:db8:1::1/64'" ]
}

@test "check_ip6 refuses IPv4" {
    run ipconfig_check_ip6 192.0.2.1 IP6_GW
    [ "$status" -eq 1 ]
    [ "$output" = "IP6_GW must be IPv6, not IPv4: '192.0.2.1' (IPv4 goes in the IP_* keys)" ]
}

@test "check_ip6 refuses what is not an address" {
    run ipconfig_check_ip6 gateway IP6_GW
    [ "$status" -eq 1 ]
    [ "$output" = "IP6_GW is not a valid IPv6 address: 'gateway'" ]
}

@test "check_ip6 refuses multicast, loopback and the unspecified address" {
    run ipconfig_check_ip6 ff02::1 IP6_DNS1
    [ "$status" -eq 1 ]
    [ "$output" = "IP6_DNS1 must be a unicast address: 'ff02::1'" ]
    run ipconfig_check_ip6 ::1 IP6_DNS1
    [ "$output" = "IP6_DNS1 must be a unicast address: '::1'" ]
    run ipconfig_check_ip6 0:0:0:0:0:0:0:1 IP6_DNS1
    [ "$output" = "IP6_DNS1 must be a unicast address: '0:0:0:0:0:0:0:1'" ]
    run ipconfig_check_ip6 :: IP6_DNS1
    [ "$output" = "IP6_DNS1 must be a unicast address: '::'" ]
}

@test "check_ip6_prefix accepts address/prefix" {
    ipconfig_check_ip6_prefix 2001:db8:1::10/64 IP6_ADDRESS
    ipconfig_check_ip6_prefix 2001:db8:1::10/128 IP6_ADDRESS
    ipconfig_check_ip6_prefix 2001:db8::/0 IP6_ADDRESS
    [ -z "$(ipconfig_check_ip6_prefix 2001:db8:1::10/64 IP6_ADDRESS)" ]
}

@test "check_ip6_prefix refuses IPv4 with and without a prefix" {
    run ipconfig_check_ip6_prefix 192.0.2.10/24 IP6_ADDRESS
    [ "$status" -eq 1 ]
    [ "$output" = "IP6_ADDRESS must be IPv6, not IPv4: '192.0.2.10/24' (IPv4 goes in the IP_* keys)" ]
    run ipconfig_check_ip6_prefix 192.0.2.10 IP6_ADDRESS
    [ "$output" = "IP6_ADDRESS must be IPv6, not IPv4: '192.0.2.10' (IPv4 goes in the IP_* keys)" ]
}

@test "check_ip6_prefix requires the prefix length" {
    run ipconfig_check_ip6_prefix 2001:db8:1::10 IP6_ADDRESS
    [ "$status" -eq 1 ]
    [ "$output" = "IP6_ADDRESS needs a prefix length, e.g. 2001:db8:1::10/64: '2001:db8:1::10'" ]
}

@test "check_ip6_prefix passes an invalid address on with its key" {
    run ipconfig_check_ip6_prefix 2001:db8:1::g/64 IP6_ADDRESS
    [ "$status" -eq 1 ]
    [ "$output" = "IP6_ADDRESS is not a valid IPv6 address: '2001:db8:1::g'" ]
    run ipconfig_check_ip6_prefix ff02::1/64 IP6_ADDRESS
    [ "$output" = "IP6_ADDRESS must be a unicast address: 'ff02::1'" ]
}

@test "check_ip6_prefix refuses a prefix length out of range" {
    run ipconfig_check_ip6_prefix 2001:db8:1::10/129 IP6_ADDRESS
    [ "$status" -eq 1 ]
    [ "$output" = "IP6_ADDRESS has an invalid prefix length (0-128): '129'" ]
    run ipconfig_check_ip6_prefix 2001:db8:1::10/6x IP6_ADDRESS
    [ "$output" = "IP6_ADDRESS has an invalid prefix length (0-128): '6x'" ]
    run ipconfig_check_ip6_prefix 2001:db8:1::10/ IP6_ADDRESS
    [ "$output" = "IP6_ADDRESS has an invalid prefix length (0-128): ''" ]
}

@test "check_ip6_prefix refuses a link-local address" {
    run ipconfig_check_ip6_prefix fe80::10/64 IP6_ADDRESS
    [ "$status" -eq 1 ]
    [ "$output" = "IP6_ADDRESS must not be link-local: 'fe80::10'" ]
    run ipconfig_check_ip6_prefix FEBF::10/64 IP6_ADDRESS
    [ "$status" -eq 1 ]
    ipconfig_check_ip6_prefix fec0::10/64 IP6_ADDRESS
}

@test "check_static6 passes with the address alone and with everything" {
    ipconfig_check_static6 2001:db8:1::10/64
    ipconfig_check_static6 2001:db8:1::10/64 fe80::1 2001:db8:1::53 2001:db8:2::53
    [ -z "$(ipconfig_check_static6 2001:db8:1::10/64 fe80::1)" ]
}

@test "check_static6 names a missing address" {
    run ipconfig_check_static6 '' fe80::1
    [ "$status" -eq 1 ]
    [ "$output" = 'IP6_CONFIG=static requires IP6_ADDRESS' ]
}

@test "check_static6 reports the first bad value with its key" {
    run ipconfig_check_static6 2001:db8:1::10 fe80::1
    [ "$output" = "IP6_ADDRESS needs a prefix length, e.g. 2001:db8:1::10/64: '2001:db8:1::10'" ]
    run ipconfig_check_static6 2001:db8:1::10/64 192.0.2.1
    [ "$status" -eq 1 ]
    [ "$output" = "IP6_GW must be IPv6, not IPv4: '192.0.2.1' (IPv4 goes in the IP_* keys)" ]
    run ipconfig_check_static6 2001:db8:1::10/64 fe80::1 192.0.2.53
    [ "$output" = "IP6_DNS1 must be IPv6, not IPv4: '192.0.2.53' (IPv4 goes in the IP_* keys)" ]
    run ipconfig_check_static6 2001:db8:1::10/64 fe80::1 2001:db8:1::53 2001:db8:2::53/64
    [ "$output" = "IP6_DNS2 must be a plain address, not address/prefix: '2001:db8:2::53/64'" ]
}

@test "render_inet6 takes the config and defaults to dhcp" {
    run ipconfig_render_inet6 eth0 host6 static
    [ "$output" = 'iface eth0 inet6 static
    hostname host6' ]
    run ipconfig_render_inet6 eth0 host6 ''
    [ "$output" = 'iface eth0 inet6 dhcp
    hostname host6' ]
}

@test "render_static6 with the address only" {
    run ipconfig_render_static6 2001:db8:1::10/64
    [ "$output" = '    address 2001:db8:1::10/64' ]
}

@test "render_static6 adds the gateway when set" {
    run ipconfig_render_static6 2001:db8:1::10/64 fe80::1
    [ "$output" = '    address 2001:db8:1::10/64
    gateway fe80::1' ]
}

@test "render_static6 joins both nameservers" {
    run ipconfig_render_static6 2001:db8:1::10/64 fe80::1 \
        2001:db8:1::53 2001:db8:2::53
    [ "$output" = '    address 2001:db8:1::10/64
    gateway fe80::1
    dns-nameservers 2001:db8:1::53 2001:db8:2::53' ]
}

@test "render_static6 writes a single nameserver without a gateway" {
    run ipconfig_render_static6 2001:db8:1::10/64 '' '' 2001:db8:2::53
    [ "$output" = '    address 2001:db8:1::10/64
    dns-nameservers 2001:db8:2::53' ]
}

# ---------------------------------------------------------------- hook, IPv6

@test "hook with IP_* keys only writes the same file as before IP6_* existed" {
    # the file 01ipconfig wrote before the IP6_* keys, byte for byte
    preseed 'IP_CONFIG=static' 'IP_ADDRESS=2001:db8:1::10' 'IP_NETMASK=64' \
        'IP_GW=2001:db8:1::1' 'IP_DNS1=2001:db8:1::53' 'IP_DNS2=2001:db8:2::53'
    run "$HOOK"
    [ "$status" -eq 0 ]
    printf '%s\n' '# UNCONFIGURED INTERFACES' \
        '# remove the above line if you edit this file' '' \
        'auto lo' 'iface lo inet loopback' '' \
        'auto eth0' 'iface eth0 inet static' '    hostname tkldev' \
        '    address 2001:db8:1::10' '    netmask 64' \
        '    gateway 2001:db8:1::1' \
        '    dns-nameservers 2001:db8:1::53 2001:db8:2::53' \
        'iface eth0 inet6 dhcp' '    hostname tkldev' > "$BATS_TEST_TMPDIR/expected"
    cmp "$BATS_TEST_TMPDIR/expected" "$INTERFACES"
    [ "$(calls ip)" = 'link set eth0 down' ]
    [ "$(calls ifup)" = '--all --exclude=lo' ]
}

@test "hook IP6_CONFIG unset keeps IPv6 on dhcp" {
    preseed 'IP_CONFIG=manual'
    run "$HOOK"
    [ "$status" -eq 0 ]
    grep -q '^iface eth0 inet6 dhcp$' "$INTERFACES"
    ! grep -q 'address' "$INTERFACES"
}

@test "hook IP6_CONFIG=dhcp writes what an unset key writes" {
    preseed 'IP_CONFIG=manual' 'IP6_CONFIG=dhcp'
    run "$HOOK"
    [ "$status" -eq 0 ]
    cp "$INTERFACES" "$BATS_TEST_TMPDIR/explicit"
    preseed 'IP_CONFIG=manual'
    echo "$STOCK_INTERFACES" > "$INTERFACES"
    run "$HOOK"
    cmp "$BATS_TEST_TMPDIR/explicit" "$INTERFACES"
}

@test "hook is fatal on an invalid IP6_CONFIG before touching anything" {
    preseed 'IP_CONFIG=dhcp' 'IP6_CONFIG=slaac'
    run "$HOOK"
    [ "$status" -eq 1 ]
    [ "$output" = "fatal Invalid: IP6_CONFIG='slaac' - valid values: manual|static|dhcp" ]
    [ "$(cat "$INTERFACES")" = "$STOCK_INTERFACES" ]
    [ -z "$(calls ip)" ]
}

@test "hook IP6 static writes address, gateway and nameservers on the inet6 stanza" {
    preseed 'IP_CONFIG=dhcp' 'IP6_CONFIG=static' 'IP6_ADDRESS=2001:db8:1::10/64' \
        'IP6_GW=fe80::1' 'IP6_DNS1=2001:db8:1::53' 'IP6_DNS2=2001:db8:2::53'
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ "$(cat "$INTERFACES")" = '# UNCONFIGURED INTERFACES
# remove the above line if you edit this file

auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
    hostname tkldev
iface eth0 inet6 static
    hostname tkldev
    address 2001:db8:1::10/64
    gateway fe80::1
    dns-nameservers 2001:db8:1::53 2001:db8:2::53' ]
    [ "$(calls ip)" = 'link set eth0 down' ]
    [ "$(calls ifup)" = '--all --exclude=lo' ]
}

@test "hook IP6 static without gateway and dns omits those lines" {
    preseed 'IP_CONFIG=dhcp' 'IP6_CONFIG=static' 'IP6_ADDRESS=2001:db8:1::10/64'
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ "$(cat "$INTERFACES")" = '# UNCONFIGURED INTERFACES
# remove the above line if you edit this file

auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
    hostname tkldev
iface eth0 inet6 static
    hostname tkldev
    address 2001:db8:1::10/64' ]
}

@test "hook IP6 static with only IP6_* keys leaves IPv4 on dhcp" {
    preseed 'IP6_CONFIG=static' 'IP6_ADDRESS=2001:db8:1::10/64' 'IP6_GW=fe80::1'
    run "$HOOK"
    [ "$status" -eq 0 ]
    grep -q '^iface eth0 inet dhcp$' "$INTERFACES"
    grep -q '^iface eth0 inet6 static$' "$INTERFACES"
    grep -q '^    gateway fe80::1$' "$INTERFACES"
    [ "$(calls ip)" = 'link set eth0 down' ]
}

@test "hook IPv4 static and IPv6 static together" {
    preseed 'IP_CONFIG=static' 'IP_ADDRESS=192.0.2.10' 'IP_NETMASK=255.255.255.0' \
        'IP_GW=192.0.2.1' 'IP_DNS1=192.0.2.53' \
        'IP6_CONFIG=static' 'IP6_ADDRESS=2001:db8:1::10/64' 'IP6_GW=2001:db8:1::1' \
        'IP6_DNS1=2001:db8:1::53'
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ "$(cat "$INTERFACES")" = '# UNCONFIGURED INTERFACES
# remove the above line if you edit this file

auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
    hostname tkldev
    address 192.0.2.10
    netmask 255.255.255.0
    gateway 192.0.2.1
    dns-nameservers 192.0.2.53
iface eth0 inet6 static
    hostname tkldev
    address 2001:db8:1::10/64
    gateway 2001:db8:1::1
    dns-nameservers 2001:db8:1::53' ]
    [ "$(calls ifup)" = '--all --exclude=lo' ]
}

@test "hook IP6 static without an address is fatal before touching anything" {
    preseed 'IP_CONFIG=dhcp' 'IP6_CONFIG=static' 'IP6_GW=fe80::1'
    run "$HOOK"
    [ "$status" -eq 1 ]
    [ "$output" = 'fatal IP6_CONFIG=static requires IP6_ADDRESS' ]
    [ "$(cat "$INTERFACES")" = "$STOCK_INTERFACES" ]
    [ -z "$(calls ip)" ]
    [ -z "$(calls ifup)" ]
}

@test "hook IP6 static with an IPv4 address is fatal" {
    preseed 'IP_CONFIG=dhcp' 'IP6_CONFIG=static' 'IP6_ADDRESS=192.0.2.10/24'
    run "$HOOK"
    [ "$status" -eq 1 ]
    [ "$output" = "fatal IP6_ADDRESS must be IPv6, not IPv4: '192.0.2.10/24' (IPv4 goes in the IP_* keys)" ]
    [ "$(cat "$INTERFACES")" = "$STOCK_INTERFACES" ]
    [ -z "$(calls ip)" ]
}

@test "hook IP6 static with an IPv4 gateway or nameserver is fatal" {
    preseed 'IP_CONFIG=dhcp' 'IP6_CONFIG=static' 'IP6_ADDRESS=2001:db8:1::10/64' \
        'IP6_GW=192.0.2.1'
    run "$HOOK"
    [ "$status" -eq 1 ]
    [ "$output" = "fatal IP6_GW must be IPv6, not IPv4: '192.0.2.1' (IPv4 goes in the IP_* keys)" ]
    preseed 'IP_CONFIG=dhcp' 'IP6_CONFIG=static' 'IP6_ADDRESS=2001:db8:1::10/64' \
        'IP6_DNS2=192.0.2.53'
    run "$HOOK"
    [ "$status" -eq 1 ]
    [ "$output" = "fatal IP6_DNS2 must be IPv6, not IPv4: '192.0.2.53' (IPv4 goes in the IP_* keys)" ]
    [ "$(cat "$INTERFACES")" = "$STOCK_INTERFACES" ]
}

@test "hook IP6 static without a prefix length is fatal" {
    preseed 'IP_CONFIG=dhcp' 'IP6_CONFIG=static' 'IP6_ADDRESS=2001:db8:1::10'
    run "$HOOK"
    [ "$status" -eq 1 ]
    [ "$output" = "fatal IP6_ADDRESS needs a prefix length, e.g. 2001:db8:1::10/64: '2001:db8:1::10'" ]
    [ -z "$(calls ip)" ]
}

@test "hook short-circuits only when both stanzas are unchanged" {
    preseed 'IP_CONFIG=dhcp' 'IP6_CONFIG=dhcp'
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ -z "$(calls ip)" ]
    preseed 'IP_CONFIG=dhcp' 'IP6_CONFIG=static' 'IP6_ADDRESS=2001:db8:1::10/64'
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ "$(calls ip)" = 'link set eth0 down' ]
    grep -q '^iface eth0 inet6 static$' "$INTERFACES"
}

@test "hook IP6 manual writes a bare inet6 stanza" {
    preseed 'IP_CONFIG=dhcp' 'IP6_CONFIG=manual'
    run "$HOOK"
    [ "$status" -eq 0 ]
    [ "$(tail -2 "$INTERFACES")" = 'iface eth0 inet6 manual
    hostname tkldev' ]
}
