#!/usr/bin/env bash
# Persistent web-terminal session on a GitHub-hosted runner.
# Usage (run via `sudo -E bash terminal.sh <cmd>`): restore | boot | hold | final | save
set -euo pipefail

STATE_DIR="${STATE_DIR:-/mnt/state}"          # host dir, bind-mounted into the container
TAG="${STATE_TAG:-terminal-state}"             # rolling release that stores encrypted snapshots
REPO="${GITHUB_REPOSITORY:?}"
WORK="${RUNNER_TEMP:-/tmp}/state-work"
IMAGE="${DEV_IMAGE:-mcr.microsoft.com/devcontainers/universal:linux}"
CNAME=dev
CUSER=codespace
KEEP=2                                         # complete snapshots to keep
CHUNK=1900M                                    # release assets are limited to 2 GiB
SAVE_EVERY="${SAVE_EVERY:-600}"                # autosave interval (seconds)
SESSION_SECONDS="${SESSION_SECONDS:-20100}"    # 5h35m, leaves room for the final save before the 6h cap

need() { command -v "$1" >/dev/null || { apt-get update -qq && apt-get install -y -qq "$2"; }; }
enc() { openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass env:STATE_PASSPHRASE "$@"; }
dec() { enc -d "$@"; }
log() { echo "[terminal] $*"; }

assets() { gh release view "$TAG" -R "$REPO" --json assets -q '.assets[].name' 2>/dev/null || true; }

# ---------------------------------------------------------------- restore
restore() {
  : "${STATE_PASSPHRASE:?}"; need zstd zstd
  rm -f "$STATE_DIR.restored"
  mkdir -p "$STATE_DIR" "$WORK"
  local stamps; stamps=$(assets | sed -n 's/^state-\([0-9]\+\)\.done$/\1/p' | sort -rn)
  if [ -z "$stamps" ]; then
    log "no snapshot found: first run"
  else
    local ok=0 ts
    for ts in $stamps; do
      log "trying snapshot $ts"
      rm -rf "$WORK"/dl "${STATE_DIR:?}"/* "$STATE_DIR"/.[!.]* 2>/dev/null || true
      mkdir -p "$WORK/dl"
      if gh release download "$TAG" -R "$REPO" -D "$WORK/dl" --pattern "state-$ts.enc.*" \
         && cat "$WORK"/dl/state-"$ts".enc.* | dec | zstd -d | tar -x -C "$STATE_DIR"; then
        ok=1; log "restored snapshot $ts"; break
      fi
      log "snapshot $ts failed, trying older"
    done
    if [ "$ok" != 1 ]; then log "ERROR: no snapshot could be restored (wrong STATE_PASSPHRASE?)"; exit 1; fi
  fi
  mkdir -p "$STATE_DIR"/{workspaces,persist,opencode/share,opencode/config,opencode/state}
  chown -R 1000:1000 "$STATE_DIR"
  touch "$STATE_DIR.restored"      # saving is refused until this exists (prevents clobbering a good snapshot)
}

# ---------------------------------------------------------------- save
save() {
  : "${STATE_PASSPHRASE:?}"
  [ -f "$STATE_DIR.restored" ] || { log "refusing to save: state was never restored"; return 1; }
  exec 9>"${RUNNER_TEMP:-/tmp}/state.lock"; flock 9
  local ts snap; ts=$(date +%s); snap="$WORK/snap"
  rm -rf "$WORK/out" "$snap"; mkdir -p "$WORK/out" "$snap"
  # 1) everything except live SQLite files (tar exit 1 = file changed while reading, acceptable)
  tar -C "$STATE_DIR" --exclude='*.db' --exclude='*.db-wal' --exclude='*.db-shm' -cf - . | tar -C "$snap" -xf - || [ $? -eq 1 ]
  # 2) SQLite files (opencode sessions) through the online-backup API => always a consistent copy
  while IFS= read -r -d '' db; do
    rel="${db#"$STATE_DIR"/}"; mkdir -p "$snap/$(dirname "$rel")"
    python3 - "$db" "$snap/$rel" <<'PY'
import sqlite3, sys
src = sqlite3.connect(sys.argv[1]); dst = sqlite3.connect(sys.argv[2])
src.backup(dst); dst.close(); src.close()
PY
  done < <(find "$STATE_DIR" -type f -name '*.db' -print0)
  # 3) tar -> zstd -> AES-256 -> split into <2 GiB chunks
  tar -C "$snap" -cf - . | zstd -T0 -3 | enc | split -b "$CHUNK" -d -a 3 - "$WORK/out/state-$ts.enc."
  ( cd "$WORK/out" && sha256sum state-"$ts".enc.* > "state-$ts.done" )
  # 4) upload chunks first, the .done marker last => half-uploaded snapshots are never used
  gh release view "$TAG" -R "$REPO" >/dev/null 2>&1 || \
    gh release create "$TAG" -R "$REPO" --title "terminal state (encrypted)" \
      --notes "Auto-managed encrypted snapshots. Do not edit." --latest=false
  gh release upload "$TAG" -R "$REPO" --clobber "$WORK"/out/state-"$ts".enc.*
  gh release upload "$TAG" -R "$REPO" --clobber "$WORK/out/state-$ts.done"
  # 5) retention: keep the newest $KEEP complete snapshots, drop everything else
  local keep_ts; keep_ts=$(assets | sed -n 's/^state-\([0-9]\+\)\.done$/\1/p' | sort -rn | head -n "$KEEP")
  local a t
  for a in $(assets); do
    t=$(echo "$a" | sed -n 's/^state-\([0-9]\+\)\..*/\1/p')
    echo "$keep_ts" | grep -qx "$t" || gh release delete-asset "$TAG" "$a" -R "$REPO" -y || true
  done
  rm -rf "$WORK/out" "$snap"
  log "saved snapshot $ts"
}

# ---------------------------------------------------------------- boot
boot() {
  log "starting container $IMAGE"
  docker rm -f $CNAME >/dev/null 2>&1 || true
  docker run -d --name $CNAME --init \
    -v "$STATE_DIR/workspaces:/workspaces" \
    -v "$STATE_DIR/persist:/persist" \
    -v "$STATE_DIR/opencode/share:/home/$CUSER/.local/share/opencode" \
    -v "$STATE_DIR/opencode/config:/home/$CUSER/.config/opencode" \
    -v "$STATE_DIR/opencode/state:/home/$CUSER/.local/state/opencode" \
    -e HISTFILE=/persist/.bash_history -e PROMPT_COMMAND='history -a' \
    -e GIT_CONFIG_GLOBAL=/persist/.gitconfig \
    "$IMAGE" sleep infinity
  local sh='bash -lc'
  docker exec -u root $CNAME $sh 'command -v tmux >/dev/null || (apt-get update -qq && apt-get install -y -qq tmux)'
  # NOTE: the npm package is `opencode-ai` (there is no @opencode/cli). V2 beta = @opencode-ai/cli@next (separate session tables) - not used here.
  docker exec -u $CUSER -e OV="${OPENCODE_VERSION:-latest}" $CNAME $sh 'npm install -g "opencode-ai@$OV" || sudo env "PATH=$PATH" npm install -g "opencode-ai@$OV"; opencode --version'
  # git identity / credentials (persisted file lives in /persist)
  [ -n "${GIT_NAME:-}" ]  && docker exec -u $CUSER $CNAME git config --global user.name  "$GIT_NAME"
  [ -n "${GIT_EMAIL:-}" ] && docker exec -u $CUSER $CNAME git config --global user.email "$GIT_EMAIL"
  if [ -n "${GIT_PAT:-}" ]; then
    docker exec -u $CUSER -e P="$GIT_PAT" $CNAME bash -c \
      'umask 077; echo "https://x-access-token:$P@github.com" > /persist/.git-credentials; git config --global credential.helper "store --file /persist/.git-credentials"'
  fi
  # first run only: clone a project into /workspaces
  if [ -n "${CLONE:-}" ] && [ -z "$(ls -A "$STATE_DIR/workspaces")" ]; then
    docker exec -u $CUSER $CNAME bash -c "cd /workspaces && git clone https://github.com/${CLONE}.git"
  fi
  # user hook: put `npm i -g ...`, `pip install ...`, `sudo apt-get install ...` in /persist/bootstrap.sh
  docker exec -u $CUSER $CNAME $sh '[ -f /persist/bootstrap.sh ] && bash /persist/bootstrap.sh || true'

  # web terminal: ttyd -> tmux inside the container (tmux survives browser reconnects)
  command -v ttyd >/dev/null || apt-get install -y -qq ttyd
  nohup ttyd -W -i 127.0.0.1 -p 7681 -c "${TTYD_USER:-dev}:${TTYD_PASS:?}" -t fontSize=16 \
    docker exec -it -u $CUSER -w /workspaces $CNAME bash -lc 'exec tmux new -A -s main' \
    >"$WORK/ttyd.log" 2>&1 &
  # tunnel
  if ! command -v cloudflared >/dev/null; then
    curl -fsSL -o "$WORK/cf.deb" https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
    dpkg -i "$WORK/cf.deb" >/dev/null
  fi
  if [ -n "${CF_TUNNEL_TOKEN:-}" ]; then
    nohup cloudflared tunnel --no-autoupdate run --token "$CF_TUNNEL_TOKEN" >"$WORK/cf.log" 2>&1 &
    log "named tunnel started (use your fixed hostname)"
  else
    nohup cloudflared tunnel --no-autoupdate --url http://127.0.0.1:7681 >"$WORK/cf.log" 2>&1 &
    local url=""
    for _ in $(seq 40); do
      url=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$WORK/cf.log" | head -1 || true)
      [ -n "$url" ] && break; sleep 2
    done
    log "terminal URL: ${url:-<not ready, see cf.log>}"
    echo "### Terminal: ${url:-pending}" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  fi
}

# ---------------------------------------------------------------- final / hold
final() {
  log "stopping container gracefully, then final save"
  docker stop -t 30 $CNAME >/dev/null 2>&1 || true
  save
}

hold() {
  local deadline=$(( ${JOB_START:?} + SESSION_SECONDS )) last; last=$(date +%s)
  log "session open until $(date -d "@$deadline" +%T)"
  while [ "$(date +%s)" -lt "$deadline" ]; do
    sleep 5
    if [ -f "$STATE_DIR/workspaces/.save-now" ]; then       # in the terminal: `touch /workspaces/.save-now`
      rm -f "$STATE_DIR/workspaces/.save-now"; save || true; last=$(date +%s)
    elif [ $(( $(date +%s) - last )) -ge "$SAVE_EVERY" ]; then
      save || log "autosave failed (will retry)"; last=$(date +%s)
    fi
  done
  final
  echo "saved=true"  >> "$GITHUB_OUTPUT"
  echo "chain=true"  >> "$GITHUB_OUTPUT"
}

"${1:?usage: terminal.sh restore|boot|hold|final|save}"
