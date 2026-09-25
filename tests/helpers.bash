# Shared helpers for the bats tests: PATH stubs and scratch paths.
#
# A stub replaces an external command for the duration of a test. It appends
# its arguments to NAME.calls (one call per line) and then runs the body the
# test gave it, so a test can both dictate the answer and inspect the call.

# setup_stubs
# Creates the stub directory of the current test and puts it first in PATH.
setup_stubs() {
    STUBS=$BATS_TEST_TMPDIR/stubs
    mkdir -p "$STUBS"
    PATH=$STUBS:$PATH
}

# stub NAME [BODY]
# Writes the stub NAME; BODY is bash, run after the call is recorded
# (default: exit 0).
stub() {
    local name=$1
    local body=${2:-exit 0}
    {
        echo '#!/bin/bash'
        echo "printf '%s\\n' \"\$*\" >> '$STUBS/$name.calls'"
        echo "$body"
    } > "$STUBS/$name"
    chmod +x "$STUBS/$name"
}

# calls NAME
# Prints the recorded calls of stub NAME, or nothing when it was never run.
calls() {
    cat "$STUBS/$1.calls" 2>/dev/null || true
}

# stub_head HOSTNAME
# Makes 'head -1 /etc/hostname' answer HOSTNAME; any other use of head is
# passed to the real one.
stub_head() {
    stub head "if [[ \"\${@: -1}\" == /etc/hostname ]]; then
    echo '$1'
else
    exec /usr/bin/head \"\$@\"
fi"
}
