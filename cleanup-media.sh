#!/usr/bin/env bash
#
# cleanup-media.sh — Total breadcrumb janitor for the Local AI Stack.
#
# Contract: when a chat is deleted in Open WebUI, the next hourly tick
# leaves no trace of it anywhere — DB, uploads, masters, logs, or
# backups. Multi-pass anti-join cleanup, schema-aware, idempotent.
#
# Phase 1 — WebUI DB orphan cleanup (surgical, inside the container):
#   * Delete rows in chat_file, chat_message, chatidtag, shared_chat,
#     automation_run whose chat_id no longer matches a live chat.
#   * Delete chat_file rows whose message_id no longer matches a live
#     chat_message (intra-chat message-edit fallout).
#   * Delete file rows with no live reference in chat_file, channel_file,
#     or knowledge_file, and rm their bytes in /app/backend/data/uploads/.
#   * Multi-pass: cascades through until stable. VACUUM at the end.
#
# Phase 2 — ComfyUI master prune (on host):
#   * Delete files in ~/ComfyUI/output/ whose mtime falls outside every
#     live chat's [created_at, updated_at + 1 h] window. Anything not
#     plausibly tied to a current chat goes.
#
# Phase 3 — ComfyUI log truncate (on host):
#   * Wipe ~/ComfyUI/comfyui.log. ComfyUI keeps writing after; old
#     contents are gone.
#
# Phase 4 — DB backup purge (inside container):
#   * Delete every webui.db.bak-* file. These are cleanup-script
#     "safety" backups (no longer created); they're recycle-bin and
#     must go. Real disaster-recovery is a separate concern.
#
# Schedule: installed by start.sh as launchd agent
# local.ai-stack.cleanup-media, fires every 3600 s (hourly).
#
# Manual:  ./cleanup-media.sh            # do it
#          ./cleanup-media.sh --dry-run  # preview without changes
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

DRY_RUN=false
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run|-n) DRY_RUN=true; shift ;;
        --help|-h)
            sed -n '3,38p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

mkdir -p "$SCRIPT_DIR/logs"
LOG="$SCRIPT_DIR/logs/cleanup-media.log"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"
}

# Load .env so COMFYUI_DIR / COMFYUI_LOG can be overridden if set there.
if [ -f .env ]; then set -a; source .env; set +a; fi
COMFYUI_DIR="${COMFYUI_DIR:-$HOME/ComfyUI}"
COMFYUI_LOG="${COMFYUI_LOG:-$COMFYUI_DIR/comfyui.log}"

log "=== cleanup-media start (dry-run=$DRY_RUN) ==="

if ! docker exec open-webui true 2>/dev/null; then
    log "ABORT: open-webui container is not running — nothing to clean."
    exit 0
fi

# ── Phase 1: WebUI DB orphan cleanup ─────────────────────────
# No backup is taken. Cleanup is anti-join only (provable orphans),
# idempotent, and dry-run-testable. "REAL delete, no recycle bin."

DRY_PY=$([ "$DRY_RUN" = true ] && echo "True" || echo "False")
docker exec -i -e "DRY_RUN_PY=$DRY_PY" open-webui python3 - <<'PYEOF' | tee -a "$LOG"
import sqlite3, os
DRY_RUN = (os.environ.get('DRY_RUN_PY', 'False') == 'True')
con = sqlite3.connect('/app/backend/data/webui.db')

# Each rule: rows in `table` whose `fk_col` doesn't match a live id in
# `parent` are anti-join orphan and get deleted. Multi-pass loop catches
# cascades (delete user → chat orphan via user_id → chat_message orphan
# via chat_id → file orphan when last chat_file ref vanishes, etc.).
RULES = [
    # Chat-rooted (chat deletion cascade)
    ('chat_file',      'chat_id',     'chat'),
    ('chat_message',   'chat_id',     'chat'),
    ('chatidtag',      'chat_id',     'chat'),
    ('shared_chat',    'chat_id',     'chat'),
    ('automation_run', 'chat_id',     'chat'),
    # Intra-chat message-edit fallout
    ('chat_file',      'message_id',  'chat_message'),
    # User-rooted (when a user is deleted, EVERYTHING they own goes)
    ('chat',           'user_id',     'user'),
    ('file',           'user_id',     'user'),
    ('tag',            'user_id',     'user'),
    ('feedback',       'user_id',     'user'),
    ('channel',        'user_id',     'user'),
    ('knowledge',      'user_id',     'user'),
    ('prompt',         'user_id',     'user'),
    ('folder',         'user_id',     'user'),
    ('model',          'user_id',     'user'),
    ('function',       'user_id',     'user'),
    ('tool',           'user_id',     'user'),
    ('skill',          'user_id',     'user'),
    ('automation',     'user_id',     'user'),
    ('memory',         'user_id',     'user'),
    ('note',           'user_id',     'user'),
    ('pinned_note',    'user_id',     'user'),
    ('document',       'user_id',     'user'),
    ('api_key',        'user_id',     'user'),
    ('oauth_session',  'user_id',     'user'),
    ('group',          'user_id',     'user'),
    ('channel_member', 'user_id',     'user'),
    ('group_member',   'user_id',     'user'),
    ('channel_webhook','user_id',     'user'),
    ('message',        'user_id',     'user'),
    ('message_reaction','user_id',    'user'),
    ('calendar',       'user_id',     'user'),
    ('calendar_event', 'user_id',     'user'),
    ('calendar_event_attendee','user_id','user'),
    # Other-entity cascades
    ('channel_file',   'channel_id',  'channel'),
    ('knowledge_file', 'knowledge_id','knowledge'),
    ('prompt_history', 'prompt_id',   'prompt'),
]

# A file is orphan iff no row in any of these tables references it AND
# no living chat.chat JSON mentions its UUID. The JSON check is what
# protects images embedded in living chats from being orphan-detected
# just because chat_file's FK happens to be missing.
FILE_REF_TABLES = ['chat_file', 'channel_file', 'knowledge_file']

existing = {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
RULES = [r for r in RULES if r[0] in existing and r[2] in existing]
FILE_REF_TABLES = [t for t in FILE_REF_TABLES if t in existing]

import re
_uuid_pat = re.compile(r'/files/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})', re.I)

def file_ids_in_living_chats():
    """All file UUIDs mentioned in any living chat's chat.chat JSON."""
    refs = set()
    for (chat_json,) in con.execute('SELECT chat FROM chat'):
        if not chat_json:
            continue
        refs.update(m.lower() for m in _uuid_pat.findall(chat_json))
    return refs

def find_orphan_files():
    json_refs = file_ids_in_living_chats()
    if not FILE_REF_TABLES and not json_refs:
        return list(con.execute('SELECT id, path FROM file'))
    where_parts = [
        f'NOT EXISTS (SELECT 1 FROM "{t}" WHERE file_id = f.id)' for t in FILE_REF_TABLES
    ]
    if json_refs:
        ph = ','.join('?' * len(json_refs))
        where_parts.append(f'LOWER(f.id) NOT IN ({ph})')
        params = list(json_refs)
    else:
        params = []
    where = ' AND '.join(where_parts) if where_parts else '1=1'
    return list(con.execute(f'SELECT f.id, f.path FROM file f WHERE {where}', params))

# Audit
print(f'Phase 1: WebUI DB cascade cleanup ({len(RULES)} rules)')
nonzero = []
for t, c, p in RULES:
    n = con.execute(
        f'SELECT COUNT(*) FROM "{t}" WHERE "{c}" IS NOT NULL AND "{c}" NOT IN (SELECT id FROM "{p}")'
    ).fetchone()[0]
    if n:
        nonzero.append((t, c, p, n))
orphan_files = find_orphan_files()
print(f'  dangling rule hits: {len(nonzero)} rule(s), {sum(n for *_, n in nonzero)} rows total')
for t, c, p, n in nonzero:
    print(f'    {t}.{c} -> {p}: {n}')
print(f'  orphan file rows: {len(orphan_files)}')

if DRY_RUN:
    print('  [dry-run] No changes.')
else:
    totals = {}
    for pass_num in range(1, 11):
        pass_deleted = 0
        for t, c, p in RULES:
            n = con.execute(
                f'DELETE FROM "{t}" WHERE "{c}" IS NOT NULL AND "{c}" NOT IN (SELECT id FROM "{p}")'
            ).rowcount
            if n:
                totals[f'{t}.{c}'] = totals.get(f'{t}.{c}', 0) + n
                pass_deleted += n
        cur_orphans = find_orphan_files()
        if cur_orphans:
            for _, path in cur_orphans:
                if not path: continue
                try: os.remove(path)
                except FileNotFoundError: pass
                except Exception as e: print(f'  ERR removing {path}: {e}')
            ids = [r[0] for r in cur_orphans]
            ph = ','.join('?'*len(ids))
            n = con.execute(f'DELETE FROM file WHERE id IN ({ph})', ids).rowcount
            totals['file'] = totals.get('file', 0) + n
            pass_deleted += n
        con.commit()
        if pass_deleted == 0: break
    else:
        print('  WARN: hit 10-pass safety cap.')
    if totals:
        summary = ', '.join(f'{k}={v}' for k, v in sorted(totals.items()))
        print(f'  removed (passes={pass_num}): {summary}')
    con.execute('VACUUM')
    print('  vacuumed.')
PYEOF

# ── Phase 2: ComfyUI output purge ────────────────────────────
# WebUI never references ComfyUI's output filenames — every PNG there
# is by construction orphan. Nuke them all.
if [ -d "$COMFYUI_DIR/output" ]; then
    n=$(find "$COMFYUI_DIR/output" -maxdepth 1 -type f -name '*.png' 2>/dev/null | wc -l | tr -d ' ')
    if [ "$DRY_RUN" = true ]; then
        log "Phase 2: [dry-run] would delete $n PNG file(s) from $COMFYUI_DIR/output/"
    else
        find "$COMFYUI_DIR/output" -maxdepth 1 -type f -name '*.png' -delete 2>/dev/null || true
        log "Phase 2: deleted $n PNG file(s) from $COMFYUI_DIR/output/"
    fi
fi

# ── Phase 3: ComfyUI log truncate ────────────────────────────
if [ -f "$COMFYUI_LOG" ]; then
    SIZE_KB=$(( $(stat -f%z "$COMFYUI_LOG" 2>/dev/null || echo 0) / 1024 ))
    if [ "$DRY_RUN" = true ]; then
        log "Phase 3: [dry-run] Would truncate $COMFYUI_LOG (currently ${SIZE_KB} KB)"
    else
        : > "$COMFYUI_LOG"
        log "Phase 3: truncated $COMFYUI_LOG (was ${SIZE_KB} KB)"
    fi
fi

# ── Phase 4: Backup pruning ──────────────────────────────────
# These are cleanup-script "safety" backups — not disaster-recovery
# backups. Per "REAL delete, no recycle bin": purge them all. Disaster
# recovery is a separate concern (Docker volume snapshots, not this).
log "Phase 4: purge cleanup-script backups (no recycle bin)"
docker exec -i -e "DRY=$([ "$DRY_RUN" = true ] && echo 1 || echo 0)" open-webui sh <<'SH' | tee -a "$LOG"
cd /app/backend/data
existing=$(ls -1 webui.db.bak-* 2>/dev/null || true)
count=$(printf '%s\n' "$existing" | grep -c . || true)
if [ "$count" -eq 0 ]; then
    echo "  No backup files to remove."
elif [ "$DRY" = "1" ]; then
    echo "  [dry-run] Would remove $count backup(s):"
    printf '%s\n' "$existing" | sed 's/^/    /'
else
    printf '%s\n' "$existing" | xargs -I{} rm -f "{}"
    echo "  Removed $count backup(s). Zero retained."
fi
SH

# ── Phase 5: Chroma vector store orphans ─────────────────────
# WebUI builds a Chroma collection named "file-<uuid>" for each uploaded
# file that goes through RAG. When the file row is gone, the collection
# is orphan — embeddings of content that no longer exists.
log "Phase 5: Chroma vector_db orphan collections"
DRY_PY=$([ "$DRY_RUN" = true ] && echo "True" || echo "False")
docker exec -i -e "DRY_RUN_PY=$DRY_PY" open-webui python3 - <<'PYEOF' | tee -a "$LOG"
import sqlite3, os, shutil
DRY = os.environ['DRY_RUN_PY'] == 'True'
chroma_dir = '/app/backend/data/vector_db'
if not os.path.isdir(chroma_dir):
    print('  vector_db not present; skipping.')
else:
    ch = sqlite3.connect(f'{chroma_dir}/chroma.sqlite3')
    wb = sqlite3.connect('/app/backend/data/webui.db')
    orphans = []
    for cid, name in ch.execute('SELECT id, name FROM collections'):
        if name.startswith('file-'):
            fid = name[5:]
            alive = wb.execute('SELECT 1 FROM file WHERE id=?', (fid,)).fetchone()
            if not alive:
                orphans.append((cid, name))
    print(f'  orphan file-* collections: {len(orphans)}')
    if not DRY and orphans:
        for cid, name in orphans:
            ch.execute('DELETE FROM collections WHERE id=?', (cid,))
            ch.execute('DELETE FROM collection_metadata WHERE collection_id=?', (cid,))
            ch.execute('DELETE FROM segments WHERE collection=?', (cid,))
            ch.execute('DELETE FROM segment_metadata WHERE segment_id IN (SELECT id FROM segments WHERE collection=?)', (cid,))
            ch.execute('DELETE FROM embeddings_queue WHERE topic LIKE ?', (f'%{cid}%',))
            d = f'{chroma_dir}/{cid}'
            if os.path.isdir(d):
                shutil.rmtree(d, ignore_errors=True)
        ch.commit()
        ch.execute('VACUUM')
        print(f'  removed {len(orphans)} collection(s) + their directories.')
    elif DRY:
        for cid, name in orphans:
            print(f'    [dry-run] would remove: {name}')
PYEOF

# ── Phase 6: WebUI cache dirs ────────────────────────────────
# Transcriptions, TTS output, and image-gen cache are all per-chat
# ephemerals. Nuke them — they regenerate on demand if needed.
log "Phase 6: cache subdir purge"
for sub in cache/audio/transcriptions cache/audio/speech cache/image/generations; do
    if [ "$DRY_RUN" = true ]; then
        n=$(docker exec open-webui sh -c "find /app/backend/data/$sub -type f 2>/dev/null | wc -l | tr -d ' '" 2>/dev/null || echo 0)
        log "  [dry-run] $sub: would delete $n files"
    else
        docker exec open-webui sh -c "find /app/backend/data/$sub -mindepth 1 -delete 2>/dev/null" || true
        log "  $sub: purged"
    fi
done

# Phase 7 (chat.chat JSON URL scrub) was removed: it modified living-chat
# content, which violates the "preserve existing chats" rule. The proper
# fix is in Phase 1's find_orphan_files(), which now also treats any
# file UUID mentioned in any living chat's chat.chat JSON as
# "referenced" — so the file row never gets orphan-deleted in the first
# place and no dangling URLs are created downstream.

# ── Phase 7: Orphan tags ─────────────────────────────────────
# WebUI stores tags two ways: as `tag` table rows AND as a JSON array
# in chat.meta.tags. The two are loosely correlated by tag.id (lower-
# case name). A tag row not referenced by any chat.meta.tags is orphan.
log "Phase 7: orphan tag cleanup"
docker exec -i -e "DRY_RUN_PY=$DRY_PY" open-webui python3 - <<'PYEOF' | tee -a "$LOG"
import sqlite3, os, json
DRY = os.environ['DRY_RUN_PY'] == 'True'
con = sqlite3.connect('/app/backend/data/webui.db')

referenced = set()
for (meta,) in con.execute('SELECT meta FROM chat'):
    try:
        m = json.loads(meta) if isinstance(meta, str) else (meta or {})
    except Exception:
        continue
    for t in (m or {}).get('tags', []) or []:
        if isinstance(t, str):
            referenced.add(t.lower())

all_tag_ids = [r[0] for r in con.execute('SELECT id FROM tag')]
orphans = [tid for tid in all_tag_ids if tid.lower() not in referenced]
print(f'  tag rows total:      {len(all_tag_ids)}')
print(f'  referenced in live chats: {len(all_tag_ids) - len(orphans)}')
print(f'  orphan tag rows:     {len(orphans)}')
if orphans and not DRY:
    ph = ','.join('?' * len(orphans))
    con.execute(f'DELETE FROM tag WHERE id IN ({ph})', orphans)
    con.commit()
    print(f'  deleted {len(orphans)} orphan tag(s).')
elif orphans and DRY:
    print(f'  [dry-run] would delete: {orphans[:10]}{"..." if len(orphans)>10 else ""}')
PYEOF

log "=== cleanup-media done ==="
