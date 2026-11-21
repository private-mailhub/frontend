#!/usr/bin/env bash
# End-to-end local fixture: real TLS/curl, no public requests, no EC2 agent or API.
set -Eeuo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd -P)
work=$(mktemp -d)
server=''
cleanup() { if [[ -n $server ]]; then kill "$server" 2>/dev/null || :; wait "$server" 2>/dev/null || :; fi; rm -rf "$work"; }
trap cleanup EXIT
export MAILHUB_DEPLOY_ROOT="$work/frontend" MAILHUB_DEPLOY_LOCK="$work/deploy.lock" TEST_FIXTURE="$work"
export REAL_CURL
REAL_CURL=$(command -v curl)
mkdir -p "$work/bin" "$work/unrelated" "$work/api"; printf 'unchanged\n' > "$work/api/state"
for tool in pm2 ssh scp aws nginx systemctl nsupdate dig; do
  cat > "$work/bin/$tool" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$0" >> "$TEST_FIXTURE/forbidden"
exit 99
STUB
  chmod +x "$work/bin/$tool"
done
# macOS lacks the util-linux CLI. Hold a real kernel flock on the inherited fd.
if ! command -v flock >/dev/null 2>&1; then
  cat > "$work/bin/flock" <<'STUB'
#!/usr/bin/env python3
import fcntl, sys
assert sys.argv[1:] == ['-x', '9']
fcntl.flock(9, fcntl.LOCK_EX)
STUB
  chmod +x "$work/bin/flock"
fi
cat > "$work/cert.conf" <<'CONF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=private-mailhub.com
[ext]
subjectAltName=DNS:private-mailhub.com
basicConstraints=critical,CA:TRUE
extendedKeyUsage=serverAuth
CONF
openssl req -newkey rsa:2048 -nodes -x509 -days 1 -sha256 -config "$work/cert.conf" \
  -keyout "$work/key" -out "$work/cert" >/dev/null 2>&1
cat > "$work/server.py" <<'SERVER'
import fcntl, http.server, os, re, ssl
from pathlib import Path
w = Path(os.environ['TEST_FIXTURE'])
root = Path(os.environ['MAILHUB_DEPLOY_ROOT'])
class Stub(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        assert self.headers['Host'] == 'private-mailhub.com'
        assert self.path == '/' or re.fullmatch(r'/assets/[a-z0-9.-]+\.js', self.path), self.path
        if not self.headers.get('X-Fixture-Fresh'):
            with open(os.environ['MAILHUB_DEPLOY_LOCK'], 'a+') as lock:
                try: fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError: pass
                else: raise AssertionError('HTTPS probe released the common lock too early')
        active = (root/'current').resolve().name
        with (w/'requests').open('a') as f: print(active, self.path, file=f)
        source = root/'current/index.html' if self.path == '/' else root/'shared'/self.path[1:]
        body = source.read_bytes()
        if (w/'bad').exists() and (w/'bad').read_text().strip() == active + ' ' + self.path:
            body = b'HTTP 200 carrying stale or fallback bytes'
        media = 'text/html; charset=utf-8' if self.path == '/' else 'text/javascript'
        if (w/'bad-mime').exists() and (w/'bad-mime').read_text().strip() == active + ' ' + self.path:
            media = 'text/plain'
        self.send_response(200); self.send_header('Content-Type', media); self.end_headers(); self.wfile.write(body)
    def log_message(self, *args): pass
srv = http.server.HTTPServer(('127.0.0.1', 0), Stub)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(w/'cert', w/'key')
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
(w/'port').write_text(str(srv.server_port)); srv.serve_forever()
SERVER
python3 "$work/server.py" >"$work/server.log" 2>&1 & server=$!
for ((i=0;i<100;i++)); do [[ -s "$work/port" ]] && break; sleep .05; done
[[ -s "$work/port" ]] || { cat "$work/server.log" >&2; exit 1; }
# Refuse any nonlocal or insecure probe BEFORE spawning curl. Only adapt the TCP
# destination port and trust store; curl itself performs real hostname/TLS checks.
cat > "$work/bin/curl" <<'STUB'
#!/usr/bin/env python3
import os, re, sys
from pathlib import Path
w = Path(os.environ['TEST_FIXTURE']); args = sys.argv[1:]
assert args[0] == '--disable'
for key, value in [('--resolve','private-mailhub.com:443:127.0.0.1'),('--noproxy','*'),('--proto','=https')]:
    assert args[args.index(key) + 1] == value
assert not {'-k','--insecure','-L','--location'}.intersection(args)
assert re.fullmatch(r'https://private-mailhub\.com/(?:assets/[a-z0-9.-]+\.js)?', args[-1])
real = os.environ['REAL_CURL']; port = (w/'port').read_text()
os.execv(real, [real, *args[:-1], '--cacert', str(w/'cert'), '--connect-to', f'private-mailhub.com:443:127.0.0.1:{port}', args[-1]])
STUB
chmod +x "$work/bin/curl"; export PATH="$work/bin:$PATH" COPYFILE_DISABLE=1
cd "$work/unrelated"  # Hooks must not assume CodeDeploy's current directory.
a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
c=cccccccccccccccccccccccccccccccccccccccc
bundle() {
  local name=$1 sha=$2 dest="$work/$1" site="$work/dist-$1"
  mkdir -p "$dest" "$site/assets"; cp -R "$repo/deploy" "$dest/"; cp "$repo/appspec.yml" "$dest/"
  printf '%s\n' "$sha" > "$dest/revision.txt"
  printf '<!doctype html><script src="https://example.invalid/ignored.js"></script><script type="module" src="/assets/%s.js"></script>\n' "$name" > "$site/index.html"
  printf 'console.log("%s");\n' "$name" > "$site/assets/$name.js"; printf 'static %s\n' "$name" > "$site/robots.txt"
  tar -czf "$dest/frontend.tar.gz" -C "$site" .
  (cd "$dest" && sha256sum frontend.tar.gz > frontend.tar.gz.sha256)
}
hook() { "$work/$1/deploy/codedeploy/$2.sh"; }
current() { [[ "$(readlink "$MAILHUB_DEPLOY_ROOT/current")" == "$MAILHUB_DEPLOY_ROOT/releases/$1" ]]; }
reject() {
  local msg=$1; shift
  if "$@" > "$work/rejected" 2>&1; then printf 'FAIL: unexpected success: %s\n' "$*" >&2; exit 1; fi
  grep -F -- "$msg" "$work/rejected" >/dev/null || { cat "$work/rejected" >&2; exit 1; }
}
fresh() {
  "$REAL_CURL" --disable --fail --silent --show-error --max-time 5 --noproxy '*' --proto '=https' \
    --cacert "$work/cert" --resolve "private-mailhub.com:443:127.0.0.1" \
    --connect-to "private-mailhub.com:443:127.0.0.1:$(cat "$work/port")" \
    -H 'X-Fixture-Fresh: 1' "https://private-mailhub.com/$1"
}
bundle one "$a"; bundle two "$b"; bundle three "$c"
hook one after-install; [[ ! -L "$MAILHUB_DEPLOY_ROOT/current" ]] || exit 1
printf '%s /\n' "$a" > "$work/bad"
reject 'Restored bootstrap state' hook one validate-service
[[ ! -e "$MAILHUB_DEPLOY_ROOT/current" && ! -L "$MAILHUB_DEPLOY_ROOT/current" ]]; rm "$work/bad"
hook one validate-service; current "$a"; [[ $(fresh '') == "$(cat "$work/dist-one/index.html")" ]]
initial=$(ls -di "$MAILHUB_DEPLOY_ROOT/releases/$a" "$MAILHUB_DEPLOY_ROOT/current")
hook one after-install; hook one validate-service
[[ $(ls -di "$MAILHUB_DEPLOY_ROOT/releases/$a" "$MAILHUB_DEPLOY_ROOT/current") == "$initial" ]]
# Legacy adoption requires the trusted SHA's exact tree, including non-entrypoint files.
rm "$MAILHUB_DEPLOY_ROOT/.release-state/$a.sha256"
hook two after-install; current "$a"
reject 'no trusted digest' hook two validate-service; current "$a"
printf 'unexpected static data\n' >> "$MAILHUB_DEPLOY_ROOT/releases/$a/robots.txt"
reject 'existing release differs' hook one after-install; current "$a"
cp "$work/dist-one/robots.txt" "$MAILHUB_DEPLOY_ROOT/releases/$a/robots.txt"
hook one validate-service
# A stale JS body with HTTP 200 after the switch must restore AND probe the old SHA.
printf '%s /assets/two.js\n' "$b" > "$work/bad"
reject "Restored and verified previous frontend $a" hook two validate-service; current "$a"
[[ $(tail -n 1 "$work/requests") == "$a /assets/one.js" ]]; mv "$work/bad" "$work/bad-mime"
reject "Restored and verified previous frontend $a" hook two validate-service; current "$a"; rm "$work/bad-mime"
hook two validate-service; current "$b"; [[ $(fresh '') == "$(cat "$work/dist-two/index.html")" ]]
[[ $(fresh assets/one.js) == "$(cat "$work/dist-one/assets/one.js")" ]]
# CodeDeploy rollback is a new deployment of the OLD bundle, never "the latest".
hook one after-install; current "$b"; hook one validate-service; current "$a"
[[ $(fresh '') == "$(cat "$work/dist-one/index.html")" && $(fresh assets/two.js) == "$(cat "$work/dist-two/assets/two.js")" ]]
# Archive corruption, fixed-SHA replacement, and stored release drift must fail closed.
printf 'changed archive' >> "$work/three/frontend.tar.gz"
reject 'checksum mismatch' hook three after-install; current "$a"
cp "$work/two/frontend.tar.gz" "$work/three/"; cp "$work/two/frontend.tar.gz.sha256" "$work/three/"
printf '%s\n' "$a" > "$work/three/revision.txt"
reject 'different bytes for immutable SHA' hook three validate-service; current "$a"
printf 'file not included in bundle' > "$MAILHUB_DEPLOY_ROOT/releases/$b/extra.txt"
reject 'existing release differs' hook two validate-service; current "$a"
rm "$MAILHUB_DEPLOY_ROOT/releases/$b/extra.txt"
printf 'changed predecessor\n' >> "$MAILHUB_DEPLOY_ROOT/releases/$a/robots.txt"
reject 'release tree no longer matches trusted digest' hook two validate-service; current "$a"
cp "$work/dist-one/robots.txt" "$MAILHUB_DEPLOY_ROOT/releases/$a/robots.txt"
printf '%s\n' 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' > "$work/three/revision.txt"
reject 'invalid revision.txt' hook three after-install; current "$a"
printf '%s\n' "$c" > "$work/three/revision.txt"; printf 'malformed checksum\n' > "$work/three/frontend.tar.gz.sha256"
reject 'expected exactly one GNU checksum' hook three after-install; current "$a"
# Simulate restart between switch and proof: recovery restores the old target first.
printf '%s %s\n' "$a" "$b" > "$MAILHUB_DEPLOY_ROOT/.release-state/pending"
rm "$MAILHUB_DEPLOY_ROOT/current"; ln -s "$MAILHUB_DEPLOY_ROOT/releases/$b" "$MAILHUB_DEPLOY_ROOT/current"
hook two after-install; current "$a"; [[ ! -e "$MAILHUB_DEPLOY_ROOT/.release-state/pending" ]]
[[ ! -e "$work/forbidden" && $(cat "$work/api/state") == unchanged && ! -s "$work/server.log" ]]
printf 'PASS: CodeDeploy bootstrap, immutable retry, trusted legacy adoption, SHA rollback, tamper rejection, locked HTTPS HTML/JS, fresh assets, crash recovery, API/PM2/DNS isolation\n'
