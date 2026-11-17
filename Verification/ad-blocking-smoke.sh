#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
bin="$(swift build --show-bin-path)"
run="$(mktemp -d)"
server=
trap 'if [[ -n "$server" ]]; then kill "$server" 2>/dev/null || true; fi; rm -rf "$run"' EXIT
if [[ -f "$bin/libSpatialMath.a" ]]; then
    module=(-I "$bin" -L "$bin" -lSpatialMath)
else
    module=(-I "$bin/Modules" "$bin"/SpatialMath.build/*.swift.o)
fi
xcrun swiftc -O "${module[@]}" \
    Sources/AdBlocking/AdBlockingStore.swift Verification/AdBlockingSmoke.swift -o "$run/smoke"
cp Resources/{web-probe.html,web-test.mp4,home.html} "$run/"
printf '%s' 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a0i8AAAAASUVORK5CYII=' | base64 -D > "$run/probe-ad.png"
python3 - "$run" <<'PY' > "$run/port" 2>"$run/server.log" &
import functools, http.server, sys
handler = functools.partial(http.server.SimpleHTTPRequestHandler,directory=sys.argv[1])
with http.server.ThreadingHTTPServer(("127.0.0.1",0),handler) as server:
    print(server.server_port,flush=True)
    server.serve_forever()
PY
server=$!
for _ in {1..50}; do [[ -s "$run/port" ]] && break; sleep 0.05; done
"$run/smoke" "http://127.0.0.1:$(cat "$run/port")/" "$@"
