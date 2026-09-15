#!/usr/bin/env bash
# Exercise server_lib.sh's process-group cleanup with a dummy server (no sglang, no GPU).
set -uo pipefail
LIB=${LIB:-/home/chen1/work/sglang-39342/test/manual/mixed_chunk_mamba/server_lib.sh}
export WS=${WS:-/tmp/cleanup_ws_39342}
export PORT=${PORT:-38455}
rm -rf "$WS"; mkdir -p "$WS"
# Dummy "server": answers 200 on /health and spawns a child so the group has several processes.
HEALTHY='python3 - <<"EOF"
import http.server, subprocess, sys, os
child = subprocess.Popen(["sleep", "3600"])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(os.environ["PORT"])), H).serve_forever()
EOF'
NEVER_HEALTHY='sleep 3600 & sleep 3600'
# A session wrapper that delays session creation: a naive parent-side pgid
# read right after fork would see the caller's group.
cat > "$WS/delayed_setsid.sh" <<'EOS'
#!/usr/bin/env bash
sleep 1.5
exec setsid "$@"
EOS
# A wrapper that never launches anything, so no handshake ever arrives.
cat > "$WS/dead_setsid.sh" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
chmod +x "$WS/delayed_setsid.sh" "$WS/dead_setsid.sh"
DELAYED_SETSID="$WS/delayed_setsid.sh"
DEAD_SETSID="$WS/dead_setsid.sh"

alive() { kill -0 -- "-$1" 2>/dev/null; }
group_members() { ps -eo pgid=,pid=,comm= | awk -v g="$1" '$1==g {print $2":"$3}' | tr '\n' ' '; }
pass=0; fail=0
report() { if [ "$2" = ok ]; then pass=$((pass+1)); echo "PASS $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }

# 1. normal start/stop kills the whole group (server + child).
out=$(bash -c "
set -euo pipefail
export SERVER_CMD='$HEALTHY' HEALTH_TIMEOUT_S=20
source $LIB
start_server t A eager case1 >/dev/null
pg=\$SERVER_PGID; echo members_before=\$(ps -eo pgid= | grep -c \"^ *\$pg\$\")
stop_server; echo pgid=\$pg; echo members_after=\$(ps -eo pgid= | grep -c \"^ *\$pg\$\")
")
echo "$out" | tr '\n' ' '; echo
echo "$out" | grep -Eq "members_before=[2-9]" && echo "$out" | grep -q "members_after=0" && report "1 normal stop kills server and child" ok || report "1 normal stop" bad

# 2. EXIT trap on a failing driver.
out=$(bash -c "
set -euo pipefail
export SERVER_CMD='$HEALTHY' HEALTH_TIMEOUT_S=20
source $LIB
start_server t A eager case2 >/dev/null
echo pgid=\$SERVER_PGID
false
" 2>/dev/null); pg=$(echo "$out" | sed -n 's/pgid=//p'); sleep 1
if [ -n "$pg" ] && ! alive "$pg"; then report "2 EXIT trap after failure" ok; else report "2 EXIT trap after failure (pg=$pg members: $(group_members "$pg"))" bad; fi

# 3. SIGINT to the driver while it waits.
bash -c "
set -euo pipefail
export SERVER_CMD='$HEALTHY' HEALTH_TIMEOUT_S=20
source $LIB
start_server t A eager case3 >/dev/null
echo \$SERVER_PGID > $WS/case3.pgid
sleep 60
" >/dev/null 2>&1 &
drv=$!; for _ in $(seq 1 60); do [ -s "$WS/case3.pgid" ] && break; sleep 0.5; done
pg=$(cat "$WS/case3.pgid"); kill -INT "$drv"; sleep 2; wait "$drv" 2>/dev/null
if ! alive "$pg"; then report "3 SIGINT cleanup" ok; else report "3 SIGINT cleanup (members: $(group_members "$pg"))" bad; fi

# 4. SIGTERM to the driver.
bash -c "
set -euo pipefail
export SERVER_CMD='$HEALTHY' HEALTH_TIMEOUT_S=20
source $LIB
start_server t A eager case4 >/dev/null
echo \$SERVER_PGID > $WS/case4.pgid
sleep 60
" >/dev/null 2>&1 &
drv=$!; for _ in $(seq 1 60); do [ -s "$WS/case4.pgid" ] && break; sleep 0.5; done
pg=$(cat "$WS/case4.pgid"); kill -TERM "$drv"; sleep 2; wait "$drv" 2>/dev/null
if ! alive "$pg"; then report "4 SIGTERM cleanup" ok; else report "4 SIGTERM cleanup (members: $(group_members "$pg"))" bad; fi

# 5. startup timeout kills the group and start_server returns nonzero.
out=$(bash -c "
set -uo pipefail
export SERVER_CMD='$NEVER_HEALTHY' HEALTH_TIMEOUT_S=4
source $LIB
start_server t A eager case5 >/dev/null 2>&1; echo rc=\$?; echo pgid=\$(cat $WS/logs/case5.pgid)
"); pg=$(echo "$out" | sed -n 's/pgid=//p'); sleep 1
echo "$out" | grep -q "rc=1" && ! alive "$pg" && report "5 startup timeout" ok || report "5 startup timeout ($out; members: $(group_members "$pg"))" bad

# 6. occupied port: refuse, and the unrelated listener survives.
python3 -c "
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self): self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', $PORT), H).serve_forever()" &
occ=$!; sleep 1
out=$(bash -c "
set -uo pipefail
export SERVER_CMD='$HEALTHY' HEALTH_TIMEOUT_S=5
source $LIB
start_server t A eager case6; echo rc=\$?
" 2>&1)
if echo "$out" | grep -q "already in use" && echo "$out" | grep -q "rc=1" && kill -0 "$occ" 2>/dev/null; then report "6 occupied port refused, listener alive" ok; else report "6 occupied port ($out)" bad; fi
kill "$occ" 2>/dev/null; wait "$occ" 2>/dev/null

# 7. delayed session creation: the handshake must still yield the child's own
#    new group, never the caller's, and stop must kill only that group while
#    the driver (same group as its own children) keeps running.
out=$(bash -c "
set -uo pipefail
export SERVER_CMD='$HEALTHY' HEALTH_TIMEOUT_S=20
export SETSID_CMD='$DELAYED_SETSID'
source $LIB
me_pgrp=\$(cut -d')' -f2 /proc/\$\$/stat | awk '{print \$3}')
start_server t A eager case7 >/dev/null; echo rc=\$?
echo caller_pgrp=\$me_pgrp server_pgid=\$SERVER_PGID server_pid=\$SERVER_PID
sleep 3600 &
sib=\$!
stop_server; echo stop_rc=\$?
sleep 0.5; kill -0 \$sib 2>/dev/null && echo sibling_alive=yes || echo sibling_alive=no
kill \$sib 2>/dev/null; wait \$sib 2>/dev/null
echo members_after=\$(ps -eo pgid= | grep -c \"^ *\$SERVER_PGID\$\")
" 2>&1)
echo "$out" | tr '\n' ' '; echo
cp=$(echo "$out" | sed -n 's/.*caller_pgrp=\([0-9]*\).*/\1/p'); sp=$(echo "$out" | sed -n 's/.*server_pgid=\([0-9]*\).*/\1/p'); spid=$(echo "$out" | sed -n 's/.*server_pid=\([0-9]*\).*/\1/p')
if echo "$out" | grep -q "^rc=0" && [ -n "$sp" ] && [ "$sp" != "$cp" ] && [ "$sp" = "$spid" ] && echo "$out" | grep -q "stop_rc=0" && echo "$out" | grep -q "sibling_alive=yes" && ! alive "$sp"; then report "7 delayed session: new group recorded, caller's group untouched" ok; else report "7 delayed session ($out)" bad; fi

# 8. no handshake (the launched command dies before reporting): start fails,
#    nothing is group-signaled, the driver and its sibling survive.
out=$(bash -c "
set -uo pipefail
export SERVER_CMD='true' HEALTH_TIMEOUT_S=5 HANDSHAKE_TIMEOUT_S=3
export SETSID_CMD='$DEAD_SETSID'
source $LIB
sleep 3600 &
sib=\$!
start_server t A eager case8 >/dev/null 2>&1; echo rc=\$?
kill -0 \$sib 2>/dev/null && echo sibling_alive=yes || echo sibling_alive=no
kill \$sib 2>/dev/null; wait \$sib 2>/dev/null
echo pgid_var=[\$SERVER_PGID]
" 2>&1)
echo "$out" | tr '\n' ' '; echo
echo "$out" | grep -q "rc=1" && echo "$out" | grep -q "sibling_alive=yes" && echo "$out" | grep -q "pgid_var=\[\]" && report "8 missing handshake: start fails without signaling any group" ok || report "8 missing handshake ($out)" bad

# 9. stop_server refuses a caller-group id even if it were injected.
out=$(bash -c "
set -uo pipefail
source $LIB
me_pgrp=\$(cut -d')' -f2 /proc/\$\$/stat | awk '{print \$3}')
sleep 3600 &
sib=\$!
SERVER_PGID=\$me_pgrp
stop_server; echo stop_rc=\$?
kill -0 \$sib 2>/dev/null && echo sibling_alive=yes || echo sibling_alive=no
kill \$sib 2>/dev/null; wait \$sib 2>/dev/null
" 2>&1)
echo "$out" | grep -q "stop_rc=1" && echo "$out" | grep -q "sibling_alive=yes" && report "9 stop_server refuses the caller's group" ok || report "9 stop_server refuses caller group ($out)" bad

echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
