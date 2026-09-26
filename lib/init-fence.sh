# Firewall and mini server functions of bin/turnkey-init-fence.
#
# Sourced by the fence and by tests/test-init-fence.bats. The functions read
# the variables of /etc/default/turnkey-init-fence (HTDOCS, HTTP_PORTS,
# HTTPS_PORTS, RUNAS, HTTP_FENCE_PORT, HTTPS_FENCE_PORT, HTTPS_FENCE_CERTFILE,
# HTTPS_FENCE_KEYFILE) plus PIDFILE, LOGFILE and INITHOOKS_PATH, all set by
# the caller.

# fence_htdocs HTDOCS PACKAGED
# Prints the directory to serve: HTDOCS when it exists, otherwise the
# PACKAGED copy (firstboot.d/29tagid creates HTDOCS, but the fence must not
# fail if it doesn't exist yet).
fence_htdocs() {
    if [[ ! -d "$1" ]]; then
        echo "$2"
    else
        echo "$1"
    fi
}

# fence_nat_available IPT
# Succeeds when the nat table of IPT (iptables or ip6tables) can be used,
# e.g. fails in a container whose host has not loaded (ip6)table_nat.
fence_nat_available() {
    "$1" -t nat -n -L PREROUTING >/dev/null 2>&1
}

iptables_delete_redirect() {
    local dport=$1
    local to_port=$2
    echo "Removing REDIRECT firewall rule: $dport => $to_port"
    while iptables -t nat -D PREROUTING -p tcp --dport "$dport" \
            -j REDIRECT --to-port "$to_port" 2>/dev/null; do
        :
    done
    while ip6tables -t nat -D PREROUTING -p tcp --dport "$dport" \
            -j REDIRECT --to-port "$to_port" 2>/dev/null; do
        :
    done
}

iptables_add_redirect() {
    local dport=$1
    local to_port=$2
    local ipt
    echo "Adding REDIRECT firewall rule: $dport => $to_port"
    iptables_delete_redirect "$dport" "$to_port"
    for ipt in iptables ip6tables; do
        # skip a family whose nat table can't be used rather than failing,
        # the fence is still reachable on $to_port
        if ! fence_nat_available "$ipt"; then
            echo "WARNING: $ipt nat table unavailable, skipping REDIRECT rule: $dport => $to_port" >&2
            continue
        fi
        $ipt -t nat -A PREROUTING -p tcp --dport "$dport" -j REDIRECT --to-port "$to_port"
    done
}

iptables_unensure_accept() {
    # Used in appliances that have a `filter` policy of `DROP`
    local dport=$1
    echo "Removing ACCEPT firewall rule for fence port: $dport"
    while iptables -t filter -D INPUT -p tcp -m tcp \
            --dport "$dport" -j ACCEPT 2>/dev/null; do
        :
    done
    while ip6tables -t filter -D INPUT -p tcp -m tcp \
            --dport "$dport" -j ACCEPT 2>/dev/null; do
        :
    done
}

iptables_ensure_accept() {
    # Used in appliances that have a `filter` policy of `DROP`
    local dport=$1
    echo "Adding ACCEPT firewall rule for fence port: $dport"
    iptables_unensure_accept "$dport"
    iptables -t filter -A INPUT -p tcp -m tcp --dport "$dport" -j ACCEPT
    ip6tables -t filter -A INPUT -p tcp -m tcp --dport "$dport" -j ACCEPT
}

iptables_redirect() {
    local op
    local mop
    local port
    case "$1" in
      start)
          op=iptables_add_redirect
          mop=iptables_ensure_accept
        ;;
      stop)
          op=iptables_delete_redirect
          mop=iptables_unensure_accept
        ;;
    esac

    for port in "${HTTP_PORTS[@]}"; do
        $op "$port" "$HTTP_FENCE_PORT"
    done

    for port in "${HTTPS_PORTS[@]}"; do
        $op "$port" "$HTTPS_FENCE_PORT"
    done

    $mop "$HTTP_FENCE_PORT"
    $mop "$HTTPS_FENCE_PORT"
}

start_mini_server() {
    echo "Starting init-fence mini-server (serving $HTDOCS)"
    touch "$LOGFILE" "$PIDFILE"
    chown -R "$RUNAS" "$HTDOCS" "$LOGFILE" "$PIDFILE"
    find "$HTDOCS" -type d -exec chmod 0555 {} \;
    find "$HTDOCS" -type f -exec chmod 0444 {} \;
    "$INITHOOKS_PATH/bin/simplehttpd.py" \
        --daemonize="$PIDFILE" \
        --runas="$RUNAS" \
        --logfile="$LOGFILE" \
        "$HTDOCS" \
        "$HTTP_FENCE_PORT" \
        "$HTTPS_FENCE_PORT" \
        "$HTTPS_FENCE_CERTFILE" \
        "$HTTPS_FENCE_KEYFILE" \
        || {
            echo "<3>init-fence mini server failed to start" >&2 \
            && exit 1
        }
}

stop_mini_server() {
    echo "Stopping init-fence mini-server"
    if [[ -f "$PIDFILE" ]]; then
        kill "$( < "$PIDFILE" )"
        rm "$PIDFILE"
    else
        echo "<4>pid file '$PIDFILE' not found" >&2
        echo "Searching for simplehttpd.py process"
        # search for process using init-fence webroot too to avoid risk of
        # killing unrelated simplehttpd.py instance
        PROC="/usr/lib/inithooks/bin/simplehttpd.py.*lib/inithooks/turnkey-init-fence/htdocs"
        if PID=$(pgrep --oldest --full "$PROC"); then
            echo "Found simplehttpd.py (pid: $PID) - killing"
            kill "$PID"
        else
            echo "<3>No simplehttpd.py process found" >&2
        fi
    fi
}
