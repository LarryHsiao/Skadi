#!/bin/bash
# Offline tests for the Flutter hot-reload daemon hook. Run from anywhere:
#   bash flutter-daemon.test.sh
#
# No real Flutter, device or simulator is involved: a stub `flutter` speaks the
# daemon protocol over the same tail-fed pipe the true one would read, so the
# wiring under test — the persistent writer that keeps the pipe from reaching
# EOF, the request ids, the result parse — is exercised exactly as it will be
# in earnest.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/flutter-daemon.sh"
pass=0
fail=0

check() { # desc expected actual
  if [[ "$2" == "$3" ]]; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

check_has() { # desc needle haystack
  if printf '%s' "$3" | grep -qF -- "$2"; then echo "  ok  · $1"; pass=$((pass + 1))
  else echo "  FAIL · $1 — [$2] absent from [$3]"; fail=$((fail + 1)); fi
}

WORK=$(mktemp -d)
export SKADI_FLUTTER_ROOT="$WORK/state"

cleanup() {
  local p
  for p in "$SKADI_FLUTTER_ROOT"/*/*/holder.pid "$SKADI_FLUTTER_ROOT"/*/*/daemon.pid; do
    [[ -f "$p" ]] && kill "$(cat "$p")" 2>/dev/null
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/bin"
# A narrow PATH keeping the utilities the hook leans on (python3, sh, tail,
# awk, sed) while excluding wherever this machine's real flutter or fvm live —
# so "neither is installed" below is a deterministic branch, not a bet on this
# developer's toolchain. python3 on Windows/MSYS commonly resolves through a
# WindowsApps execution-alias directory rather than /usr/bin or /bin, so its
# real directory is discovered rather than assumed — appended last, since that
# same directory also holds a broken `bash` alias (a WSL launcher stub) that
# must never shadow the real /usr/bin/bash this whole script depends on.
PY3_DIR=""
command -v python3 >/dev/null 2>&1 && PY3_DIR="$(dirname "$(command -v python3)")"
BARE_PATH="$WORK/bin:/usr/bin:/bin${PY3_DIR:+:$PY3_DIR}"

STUB_LOG="$WORK/argv.log"
export STUB_LOG
: > "$STUB_LOG"

# The stub daemon: announces itself as flutter's does — prose first, then the
# protocol — and answers every request it is given until its stdin closes.
cat > "$WORK/bin/flutter" <<'STUB'
#!/bin/bash
echo "$*" >> "$STUB_LOG"
echo "cwd=$PWD" >> "$STUB_LOG"
if [ "${STUB_NO_START:-0}" = "1" ]; then
  echo '[{"event":"daemon.connected","params":{"version":"0.6.1","pid":1}}]'
else
  echo 'Launching lib/main.dart on stub device in debug mode...'
  echo '[{"event":"daemon.connected","params":{"version":"0.6.1","pid":1}}]'
  echo '[{"event":"app.start","params":{"appId":"stub-app-1","deviceId":"stub","supportsRestart":true}}]'
  echo '[{"event":"app.started","params":{"appId":"stub-app-1"}}]'
fi
[ "${STUB_DIE_AFTER_START:-0}" = "1" ] && exit 1
while IFS= read -r line; do
  echo "$line" >> "$STUB_IN"
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
  case "$line" in
    *app.stop*) echo "[{\"id\":$id,\"result\":{\"code\":0,\"message\":\"stopped\"}}]"; break ;;
  esac
  if [ "${STUB_FAIL:-0}" = "1" ]; then
    echo "[{\"id\":$id,\"result\":{\"code\":1,\"message\":\"reload rejected\"}}]"
  else
    echo "[{\"id\":$id,\"result\":{\"code\":0,\"message\":\"ok\"}}]"
  fi
done
STUB
chmod +x "$WORK/bin/flutter"

new_project() { # name
  mkdir -p "$WORK/$1"
  printf 'name: %s\n' "$1" > "$WORK/$1/pubspec.yaml"
  echo "$WORK/$1"
}

# ── argument handling ──
out=$("$HOOK" 2>/dev/null); st=$?
check "no verb at all exits 2" "2" "$st"

out=$("$HOOK" frobnicate 2>/dev/null); st=$?
check "an unknown verb exits 2" "2" "$st"

out=$("$HOOK" status --project 2>/dev/null); st=$?
check "a flag with no value exits 2" "2" "$st"

# ── a project with no pubspec is refused before flutter is even sought ──
mkdir -p "$WORK/bare"
out=$(PATH="$BARE_PATH" "$HOOK" start --project "$WORK/bare" 2>/dev/null); st=$?
check "a project with no pubspec.yaml exits 4" "4" "$st"

# ── neither flutter nor fvm on PATH ──
projA=$(new_project appA)
out=$(PATH="/usr/bin:/bin" "$HOOK" start --project "$projA" 2>/dev/null); st=$?
check "no flutter and no fvm on PATH exits 3" "3" "$st"

# ── reload before any daemon exists ──
out=$(PATH="$BARE_PATH" "$HOOK" reload --project "$projA" 2>/dev/null); st=$?
check "reload with no daemon exits 4" "4" "$st"

out=$(PATH="$BARE_PATH" "$HOOK" status --project "$projA" 2>/dev/null); st=$?
check "status with no daemon exits 4" "4" "$st"

out=$(PATH="$BARE_PATH" "$HOOK" log --project "$projA" 2>/dev/null); st=$?
check "log with no daemon exits 4" "4" "$st"

# ── start: the daemon comes up and, crucially, stays up ──
export STUB_IN="$WORK/a.in"
: > "$STUB_IN"
out=$(PATH="$BARE_PATH" "$HOOK" start --project "$projA" -d stub-device \
  --flavor jp -t lib/main_jp.dart --timeout 20 -- --debug 2>&1); st=$?
check "start exits 0" "0" "$st"
check_has "start names the appId it learned" "started stub-app-1" "$out"

dirA=$(echo "$SKADI_FLUTTER_ROOT"/appA-*/*)
check "the command file is laid down" "1" "$([[ -f "$dirA/cmds" ]] && echo 1 || echo 0)"
check "the daemon pid is recorded" "1" "$([[ -s "$dirA/daemon.pid" ]] && echo 1 || echo 0)"
check "the holder pid is recorded" "1" "$([[ -s "$dirA/holder.pid" ]] && echo 1 || echo 0)"
check "the appId is persisted to meta" "stub-app-1" "$(sed -n 's/^appId=//p' "$dirA/meta")"

# The whole point of the persistent writer: the daemon must outlive the start call
# that spawned it, rather than dying on the EOF a closing writer would send.
check "the daemon outlives the start call" "0" \
  "$(kill -0 "$(cat "$dirA/daemon.pid")" 2>/dev/null; echo $?)"

check_has "the device reaches flutter as -d <id>" "-d stub-device" "$(cat "$STUB_LOG")"
check_has "the flavor reaches flutter" "--flavor jp" "$(cat "$STUB_LOG")"
check_has "the entry point reaches flutter" "-t lib/main_jp.dart" "$(cat "$STUB_LOG")"
check_has "args after -- reach flutter verbatim" "--debug" "$(cat "$STUB_LOG")"
check_has "the daemon protocol is asked for" "run --machine" "$(cat "$STUB_LOG")"
# `flutter run` reads pubspec.yaml from its own working directory, so the daemon
# must stand in the project, not wherever the caller happened to be.
check_has "the daemon is spoken from the project root" "cwd=$projA" "$(cat "$STUB_LOG")"

# ── status on a live daemon ──
out=$(PATH="$BARE_PATH" "$HOOK" status --project "$projA" 2>&1); st=$?
check "status on a live daemon exits 0" "0" "$st"
check_has "status names it alive with its appId" "alive stub-app-1" "$out"

# ── start again: the live daemon is reused, not replaced ──
was=$(cat "$dirA/daemon.pid")
out=$(PATH="$BARE_PATH" "$HOOK" start --project "$projA" 2>&1); st=$?
check "a second start exits 0" "0" "$st"
check_has "a second start reports the daemon already alive" "alive stub-app-1" "$out"
check "a second start does not respawn the daemon" "$was" "$(cat "$dirA/daemon.pid")"

# ── reload ──
out=$(PATH="$BARE_PATH" "$HOOK" reload --project "$projA" --timeout 20 2>&1); st=$?
check "reload exits 0" "0" "$st"
check_has "reload reports what the daemon answered" "reloaded stub-app-1" "$out"
check_has "reload asks for app.restart" '"method":"app.restart"' "$(cat "$STUB_IN")"
check_has "reload asks for a hot reload, not a restart" '"fullRestart":false' "$(cat "$STUB_IN")"
check_has "reload names the appId" '"appId":"stub-app-1"' "$(cat "$STUB_IN")"

# ── restart is the same poke with the full flag set ──
: > "$STUB_IN"
out=$(PATH="$BARE_PATH" "$HOOK" restart --project "$projA" --timeout 20 2>&1); st=$?
check "restart exits 0" "0" "$st"
check_has "restart reports what the daemon answered" "restarted stub-app-1" "$out"
check_has "restart asks for a full restart" '"fullRestart":true' "$(cat "$STUB_IN")"

# ── request ids advance, so one answer is never read as another's ──
check "the request counter advanced past the first poke" "1" \
  "$([[ "$(cat "$dirA/req")" -ge 2 ]] && echo 1 || echo 0)"

# ── a bare verb inside the project tree finds its own daemon ──
mkdir -p "$projA/lib/nested"
out=$(cd "$projA/lib/nested" && PATH="$BARE_PATH" "$HOOK" reload --timeout 20 2>&1); st=$?
check "reload from a subdirectory exits 0" "0" "$st"
check_has "reload from a subdirectory finds the same app" "reloaded stub-app-1" "$out"

# ── log surfaces the daemon's own transcript ──
out=$(PATH="$BARE_PATH" "$HOOK" log --project "$projA" -n 20 2>&1); st=$?
check "log exits 0" "0" "$st"
check_has "log shows the daemon's own events" "app.started" "$out"

# ── stop tears the whole thing down ──
holderA=$(cat "$dirA/holder.pid")
out=$(PATH="$BARE_PATH" "$HOOK" stop --project "$projA" 2>&1); st=$?
check "stop exits 0" "0" "$st"
check "stop removes the state directory" "0" "$([[ -d "$dirA" ]] && echo 1 || echo 0)"
check "stop kills the pipe holder" "1" "$(kill -0 "$holderA" 2>/dev/null; echo $?)"

# ── a corpse is named as one, and never poked ──
projB=$(new_project appB)
export STUB_IN="$WORK/b.in"
: > "$STUB_IN"
PATH="$BARE_PATH" "$HOOK" start --project "$projB" --timeout 20 >/dev/null 2>&1
dirB=$(echo "$SKADI_FLUTTER_ROOT"/appB-*/*)
kill "$(cat "$dirB/daemon.pid")" 2>/dev/null
sleep 0.5
out=$(PATH="$BARE_PATH" "$HOOK" status --project "$projB" 2>&1); st=$?
check "status on a dead daemon exits 5" "5" "$st"
check_has "status names the daemon dead" "dead" "$out"
out=$(PATH="$BARE_PATH" "$HOOK" reload --project "$projB" 2>&1); st=$?
check "reload into a dead daemon exits 5" "5" "$st"
check "reload into a dead daemon writes nothing to the pipe" "0" "$(wc -l < "$STUB_IN" | tr -d ' ')"
PATH="$BARE_PATH" "$HOOK" stop --project "$projB" >/dev/null 2>&1

# ── starting over a corpse reaps its pipe holder, not only its state ──
# A holder left alive would sit on a command file whose directory has been
# removed, and one more would be stranded on every restart-after-death.
projF=$(new_project appF)
export STUB_IN="$WORK/f.in"
: > "$STUB_IN"
PATH="$BARE_PATH" "$HOOK" start --project "$projF" --timeout 20 >/dev/null 2>&1
dirF=$(echo "$SKADI_FLUTTER_ROOT"/appF-*/*)
holderF=$(cat "$dirF/holder.pid")
kill "$(cat "$dirF/daemon.pid")" 2>/dev/null
sleep 0.5
PATH="$BARE_PATH" "$HOOK" start --project "$projF" --timeout 20 >/dev/null 2>&1
sleep 0.5
check "starting over a corpse kills the old pipe holder" "1" \
  "$(kill -0 "$holderF" 2>/dev/null; echo $?)"
check "starting over a corpse raises a new holder" "1" \
  "$([[ "$(cat "$dirF/holder.pid")" != "$holderF" ]] && echo 1 || echo 0)"
PATH="$BARE_PATH" "$HOOK" stop --project "$projF" >/dev/null 2>&1

# ── a state directory bearing no log is not a daemon ──
# A spawn that fails to lay down its command file leaves exactly that shape
# behind. Every verb that reads the log must answer "no daemon" rather than
# letting tail meet a file that is not there and report a filesystem error in
# its place.
projG=$(new_project appG)
export STUB_IN="$WORK/g.in"
: > "$STUB_IN"
PATH="$BARE_PATH" "$HOOK" start --project "$projG" --timeout 20 >/dev/null 2>&1
dirG=$(echo "$SKADI_FLUTTER_ROOT"/appG-*/*)
rm -f "$dirG/log"
for verb in log reload restart; do
  out=$(PATH="$BARE_PATH" "$HOOK" "$verb" --project "$projG" 2>&1); st=$?
  check "$verb on a state dir bearing no log exits 4" "4" "$st"
  check_has "$verb on a state dir bearing no log says so plainly" "no daemon for" "$out"
done
PATH="$BARE_PATH" "$HOOK" stop --project "$projG" >/dev/null 2>&1

# ── a reload the daemon rejects fails loud rather than reading as success ──
projC=$(new_project appC)
export STUB_IN="$WORK/c.in"
: > "$STUB_IN"
STUB_FAIL=1 PATH="$BARE_PATH" "$HOOK" start --project "$projC" --timeout 20 >/dev/null 2>&1
out=$(PATH="$BARE_PATH" "$HOOK" reload --project "$projC" --timeout 20 2>&1); st=$?
check "a rejected reload exits 7" "7" "$st"
check_has "a rejected reload surfaces the daemon's reason" "reload rejected" "$out"
PATH="$BARE_PATH" "$HOOK" stop --project "$projC" >/dev/null 2>&1

# ── an app that never starts is not mistaken for one that did ──
projD=$(new_project appD)
export STUB_IN="$WORK/d.in"
: > "$STUB_IN"
out=$(STUB_NO_START=1 PATH="$BARE_PATH" "$HOOK" start --project "$projD" --timeout 2 2>&1); st=$?
check "a build that never reaches app.started exits 6" "6" "$st"
out=$(PATH="$BARE_PATH" "$HOOK" status --project "$projD" 2>&1); st=$?
check "status on a not-yet-started app exits 6" "6" "$st"
check_has "status says it is still starting" "starting" "$out"
out=$(PATH="$BARE_PATH" "$HOOK" reload --project "$projD" 2>&1); st=$?
check "reload before app.started exits 6" "6" "$st"
PATH="$BARE_PATH" "$HOOK" stop --project "$projD" >/dev/null 2>&1

# ── an app that starts and dies in the same breath is not a success ──
projE=$(new_project appE)
export STUB_IN="$WORK/e.in"
: > "$STUB_IN"
out=$(STUB_DIE_AFTER_START=1 PATH="$BARE_PATH" "$HOOK" start --project "$projE" --timeout 20 2>&1); st=$?
check "a daemon that dies right after app.started exits 5" "5" "$st"
check_has "that death is named rather than reported as a start" "then the daemon died" "$out"
PATH="$BARE_PATH" "$HOOK" stop --project "$projE" >/dev/null 2>&1

# ── multi-device: a second start with a DIFFERENT -d raises a sibling ──
projH=$(new_project appH)
export STUB_IN="$WORK/h1.in"
: > "$STUB_IN"
PATH="$BARE_PATH" "$HOOK" start --project "$projH" -d simA --timeout 20 >/dev/null 2>&1
dirH_A=$(echo "$SKADI_FLUTTER_ROOT"/appH-*/simA)
wasA=$(cat "$dirH_A/daemon.pid")

export STUB_IN="$WORK/h2.in"
: > "$STUB_IN"
out=$(PATH="$BARE_PATH" "$HOOK" start --project "$projH" -d simB --timeout 20 2>&1); st=$?
check "a second device's start exits 0" "0" "$st"
check_has "the second device is reported as started, not alive" "started stub-app-1" "$out"
dirH_B=$(echo "$SKADI_FLUTTER_ROOT"/appH-*/simB)
check "the second device gets its own state dir" "1" "$([[ -d "$dirH_B" ]] && echo 1 || echo 0)"
check "the first device's daemon is untouched" "$wasA" "$(cat "$dirH_A/daemon.pid")"

# ── an unqualified start refuses once two devices already stand ──
out=$(PATH="$BARE_PATH" "$HOOK" start --project "$projH" --timeout 20 2>&1); st=$?
check "an unqualified start with two devices already up exits 2" "2" "$st"
check_has "it names the ambiguity rather than guessing" "several devices already run" "$out"

# ── status with no -d lists every live device once more than one stands ──
out=$(PATH="$BARE_PATH" "$HOOK" status --project "$projH" 2>&1); st=$?
check "multi-device status exits 0" "0" "$st"
check_has "multi-device status names simA" "device simA" "$out"
check_has "multi-device status names simB" "device simB" "$out"

# ── reload with no -d reaches every live device ──
out=$(PATH="$BARE_PATH" "$HOOK" reload --project "$projH" --timeout 20 2>&1); st=$?
check "multi-device reload exits 0" "0" "$st"
check_has "multi-device reload reports simA" "[simA] reloaded" "$out"
check_has "multi-device reload reports simB" "[simB] reloaded" "$out"
check_has "simA's own daemon received the reload" '"method":"app.restart"' "$(cat "$WORK/h1.in")"
check_has "simB's own daemon received the reload" '"method":"app.restart"' "$(cat "$WORK/h2.in")"

# ── an explicit -d targets one device only, leaving the other's pipe untouched ──
before_b="$(wc -l < "$WORK/h2.in" | tr -d ' ')"
out=$(PATH="$BARE_PATH" "$HOOK" reload --project "$projH" -d simA --timeout 20 2>&1); st=$?
check "an explicit -d reload exits 0" "0" "$st"
check_has "it names only that device, not both" "reloaded stub-app-1" "$out"
after_b="$(wc -l < "$WORK/h2.in" | tr -d ' ')"
check "it leaves the other device's pipe untouched" "$before_b" "$after_b"

# ── log with no -d refuses to interleave several transcripts ──
out=$(PATH="$BARE_PATH" "$HOOK" log --project "$projH" 2>&1); st=$?
check "log with no -d exits 2 once two devices stand" "2" "$st"
check_has "it names the ambiguity" "multiple devices running" "$out"
out=$(PATH="$BARE_PATH" "$HOOK" log --project "$projH" -d simA -n 20 2>&1); st=$?
check "log with an explicit -d exits 0" "0" "$st"

# ── multi-device status/stop propagate the worst code, not a blanket 0 ──
# A fan-out must not paper over one device having died just because the
# others are fine — the exit code is the contract, per the hook's own header.
kill "$(cat "$dirH_B/daemon.pid")" 2>/dev/null
sleep 0.5
out=$(PATH="$BARE_PATH" "$HOOK" status --project "$projH" 2>&1); st=$?
check "multi-device status exits the worst code once one device died" "5" "$st"
check_has "the dead device is still named dead" "dead" "$out"
check_has "the live device is still named alive" "alive stub-app-1" "$out"

# ── stop with no -d tears down every device ──
holderH_A=$(cat "$dirH_A/holder.pid")
holderH_B=$(cat "$dirH_B/holder.pid")
out=$(PATH="$BARE_PATH" "$HOOK" stop --project "$projH" 2>&1); st=$?
check "multi-device stop exits 0" "0" "$st"
check "multi-device stop removes simA's state dir" "0" "$([[ -d "$dirH_A" ]] && echo 1 || echo 0)"
check "multi-device stop removes simB's state dir" "0" "$([[ -d "$dirH_B" ]] && echo 1 || echo 0)"
check "multi-device stop kills simA's pipe holder" "1" "$(kill -0 "$holderH_A" 2>/dev/null; echo $?)"
check "multi-device stop kills simB's pipe holder" "1" "$(kill -0 "$holderH_B" 2>/dev/null; echo $?)"

echo ""
echo "── $pass passed, $fail failed ──"
[[ "$fail" -eq 0 ]]
