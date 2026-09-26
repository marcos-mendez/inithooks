# Decisions and rendering for firstboot.d/01ipconfig.
#
# Sourced by the hook and by tests/test-ipconfig.bats. Every function here
# only reads its arguments and prints; the hook applies the results.

# ipconfig_valid_config CONFIG
# Succeeds when CONFIG is a value IP_CONFIG accepts.
ipconfig_valid_config() {
    case "$1" in
        manual|static|dhcp)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# ipconfig_iface CODENAME
# Prints the interface configured for a build codename (turnkey-version -n).
ipconfig_iface() {
    if [[ "$1" == "lxc" ]]; then
        # LXC app not currently being built, but leaving for now...
        echo "br0"
    else
        echo "eth0"
    fi
}

# ipconfig_unchanged FILE IFACE CONFIG
# Succeeds when the interfaces FILE already configures IFACE with CONFIG.
ipconfig_unchanged() {
    grep --quiet --no-messages "iface $2 inet $3" "$1"
}

# ipconfig_render_head IFACE CONFIG HOSTNAME
# Prints the header confconsole looks for (otherwise it refuses to edit the
# file), the loopback stanza and the IPv4 stanza of IFACE.
ipconfig_render_head() {
    local iface=$1
    local config=$2
    local hostname=$3
    cat <<EOT
# UNCONFIGURED INTERFACES
# remove the above line if you edit this file

auto lo
iface lo inet loopback

auto $iface
iface $iface inet $config
    hostname $hostname
EOT
}

# ipconfig_check_static ADDRESS NETMASK
# Succeeds when both are set; otherwise prints why not and fails.
ipconfig_check_static() {
    [[ -n "$1" ]] || { echo "IP_CONFIG=static requires IP_ADDRESS"; return 1; }
    [[ -n "$2" ]] || { echo "IP_CONFIG=static requires IP_NETMASK"; return 1; }
}

# ipconfig_render_static ADDRESS NETMASK [GATEWAY [DNS1 [DNS2]]]
# Prints the options of a static stanza; gateway and dns-nameservers only
# when set.
ipconfig_render_static() {
    local address=$1
    local netmask=$2
    local gateway=$3
    local dns
    echo "    address $address"
    echo "    netmask $netmask"
    [[ -z "$gateway" ]] || echo "    gateway $gateway"
    dns=$(echo "$4 $5" | xargs)
    [[ -z "$dns" ]] || echo "    dns-nameservers $dns"
}

# ipconfig_render_inet6 IFACE HOSTNAME
# Prints the IPv6 stanza. Like confconsole, the hook only configures IPv4
# and keeps IPv6 on (SLAAC/DHCPv6).
ipconfig_render_inet6() {
    local iface=$1
    local hostname=$2
    cat <<EOT
iface $iface inet6 dhcp
    hostname $hostname
EOT
}
