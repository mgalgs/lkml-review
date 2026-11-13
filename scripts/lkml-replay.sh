#!/usr/bin/env bash
# Replay one fleet seat through fork-sandbox's local postmaster.
#
# With --session-transcript/--session-id/--session-cut (claude seats only)
# the wake resumes the live seat's conversation as it stood at the cut,
# seeded where the postmaster's own resume path finds it. A wake that does
# not resume that id exits 3 after recording; see docs/replay.md.
set -euo pipefail

usage() { echo 'Usage: lkml-replay.sh --export JSON --cut SEQ --seat NAME --personas-ref SHA --project DIR --model M --thinking T [--personas-overlay DIR] [--no-review-target] [--attachments-dir DIR] [--allow-missing-attachments] [--fork-sandbox DIR] [--work-dir DIR] [--timeout SECONDS] [--claude-credentials FILE] [--session-transcript FILE --session-id ID --session-cut ISO-8601-UTC [--live-cli-version V]]'; }
die() { echo "Error: $*" >&2; exit 2; }
repo=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
export_file='' cut='' seat='' ref='' project='' model='' thinking='' attachments_dir='' personas_overlay='' fork_sandbox='' work='' timeout=3600 allow_missing=0 no_review_target=0
session_transcript='' session_id='' session_cut='' live_cli_version='' claude_credentials=''
while (($#)); do
    case "$1" in
        --export|--cut|--seat|--personas-ref|--project|--model|--thinking|--attachments-dir|--personas-overlay|--fork-sandbox|--work-dir|--timeout|--session-transcript|--session-id|--session-cut|--live-cli-version|--claude-credentials)
            (($# >= 2)) || die "$1 requires a value"
            case "$1" in
                --export) export_file=$2;; --cut) cut=$2;; --seat) seat=$2;; --personas-ref) ref=$2;; --project) project=$2;;
                --model) model=$2;; --thinking) thinking=$2;; --attachments-dir) attachments_dir=$2;;
                --personas-overlay) personas_overlay=$2;;
                --fork-sandbox) fork_sandbox=$2;; --work-dir) work=$2;; --timeout) timeout=$2;;
                --session-transcript) session_transcript=$2;; --session-id) session_id=$2;;
                --session-cut) session_cut=$2;; --live-cli-version) live_cli_version=$2;;
                --claude-credentials) claude_credentials=$2;;
            esac
            shift 2;;
        --allow-missing-attachments) allow_missing=1; shift;;
        --no-review-target) no_review_target=1; shift;;
        -h|--help) usage; exit 0;;
        *) die "unknown option '$1'";;
    esac
done
[[ -f "$export_file" && -n "$cut" && -n "$seat" && -n "$ref" && -d "$project" ]] || { usage >&2; exit 2; }
[[ -n "$model" ]] || die '--model is required'
[[ -n "$thinking" ]] || die '--thinking is required'
[[ "$cut" =~ ^[1-9][0-9]*$ && "$timeout" =~ ^[1-9][0-9]*$ && "$seat" =~ ^[a-z][a-z0-9-]*$ ]] || die 'invalid cut, timeout or seat'
export_file=$(readlink -f "$export_file")
project=$(readlink -f "$project")
resume=0
if [[ -n "$session_transcript" || -n "$session_id" || -n "$session_cut" ]]; then
    [[ -n "$session_transcript" && -n "$session_id" && -n "$session_cut" ]] \
        || die '--session-transcript, --session-id and --session-cut go together'
    [[ -f "$session_transcript" ]] || die "session transcript missing: $session_transcript"
    # The shape the postmaster accepts for a session it resumes.
    [[ "$session_id" =~ ^[0-9a-f][0-9a-f-]{7,63}$ ]] || die 'invalid session id'
    [[ "$session_cut" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|\+00:00)$ ]] \
        || die '--session-cut must be an ISO-8601 UTC time'
    session_transcript=$(readlink -f "$session_transcript")
    resume=1
fi
[[ -z "$attachments_dir" ]] || attachments_dir=$(readlink -f "$attachments_dir")
if [[ -n "$claude_credentials" ]]; then
    [[ -f "$claude_credentials" ]] || die "claude credentials missing: $claude_credentials"
    claude_credentials=$(readlink -f "$claude_credentials")
fi
if [[ -n "$personas_overlay" ]]; then
    [[ -d "$personas_overlay" ]] || die 'personas overlay directory missing'
    personas_overlay=$(readlink -f "$personas_overlay")
fi
ref=$(git -C "$repo" rev-parse --verify "$ref^{commit}") || die 'unknown personas ref'
if [[ -n "$fork_sandbox" ]]; then
    fork_sandbox=$(readlink -f "$fork_sandbox")
else
    fork_sandbox=$(dirname "$(dirname "$(readlink -f "$(command -v fork-sandbox)")")")
fi
[[ -x "$fork_sandbox/scripts/fork-sandbox-postmaster.sh" ]] || die 'fork-sandbox checkout missing'
fork_ref=$(git -C "$fork_sandbox" rev-parse HEAD 2>/dev/null || true)
fork_ref=${fork_ref:-${FORK_SANDBOX_COMMIT:-unknown}}
if [[ -z "$work" ]]; then work=$(mktemp -d /var/tmp/claude-scratch/lkml-replay.XXXXXX); else mkdir -p -- "$work"; work=$(readlink -f "$work"); fi
[[ "$work" == /var/tmp/claude-scratch/* && "$work" != /var/tmp/claude-scratch/forks/* ]] || die 'work dir must be under /var/tmp/claude-scratch, outside forks'
[[ -z "$(ls -A "$work")" ]] || die 'work dir must be empty'
mkdir -p "$work/text" "$work/config" "$work/mail" "$work/hooks" "$work/runs" "$work/personas"
# fork-sandbox reads the credential pin from claude.env in its config dir.
[[ -z "$claude_credentials" ]] || printf 'CLAUDE_CREDENTIALS=%s\n' "$claude_credentials" > "$work/config/claude.env"
git -C "$repo" archive "$ref" fleet/personas fleet/prompts | tar -x -C "$work/text" || die 'could not extract persona text'
overlay_files=()
if [[ -n "$personas_overlay" ]]; then
    for persona_file in "$personas_overlay"/*.md; do
        [[ -f "$persona_file" ]] || continue
        cp -- "$persona_file" "$work/text/fleet/personas/$(basename "$persona_file")"
        overlay_files+=("$(basename "$persona_file")")
    done
fi
[[ -f "$work/text/fleet/personas/$seat.md" ]] || die "unknown seat '$seat' at ref"
cp -- "$work/text/fleet/personas/$seat.md" "$work/personas/$seat.md"
export FORK_SANDBOX_MAIL_ROOT="$work/mail" FORK_SANDBOX_CONFIG_DIR="$work/config"
export FORK_SANDBOX_PERSONAS_DIR="$work/personas" FORK_SANDBOX_PROMPTS_DIR="$work/text/fleet/prompts"
export FORK_SANDBOX_FLEET_FILE="$work/config/fleet.yaml" FORK_SANDBOX_HOOKS_DIR="$work/hooks"
export FORK_SANDBOX_POSTMASTER_DEBOUNCE=0 FORK_SANDBOX_POSTMASTER_LAUNCHER="${FORK_SANDBOX_POSTMASTER_LAUNCHER:-$fork_sandbox/scripts/fork-sandbox.sh}"
[[ "$FORK_SANDBOX_POSTMASTER_LAUNCHER" == "$fork_sandbox/scripts/fork-sandbox.sh" ]] || echo "Warning: nonstandard postmaster launcher: $FORK_SANDBOX_POSTMASTER_LAUNCHER" >&2
unset FORK_SANDBOX_MAIL_API_URL FORK_SANDBOX_MAIL_API_TOKEN_FILE FORK_SANDBOX_MAIL_API_RETRY_SECONDS
python3 - "$export_file" "$cut" "$seat" "$work" "$attachments_dir" "$allow_missing" "$no_review_target" <<'PY' || die 'could not seed export'
import json, pathlib, re, shutil, sys
source,cut,seat,work,attach_dir,allow,no_target=sys.argv[1:]
cut=int(cut); root=pathlib.Path(work); data=json.load(open(source)); messages=data['messages']
if len(messages)<cut or [m['seq'] for m in messages[:cut]]!=list(range(1,cut+1)):
    sys.exit('Error: cut beyond export or non-contiguous sequence')
tid=data['thread']
if not re.fullmatch(r'[0-9a-f-]{36}',tid): sys.exit('Error: invalid thread id')
trigger=messages[cut-1]
addresses=trigger['to']+trigger['cc']
if '@'+seat not in addresses:
    sys.exit('Error: cut not addressed directly to seat')
other={a[1:] for a in addresses if a.startswith('@') and a!='@'+seat and a not in ('@operator','@all')}
thread=root/'mail'/'threads'/tid; thread.mkdir(parents=True)
missing=[]
for m in messages[:cut]:
    mid=m['id']
    if not re.fullmatch(r'[0-9a-f-]{36}',mid): sys.exit('Error: invalid message id')
    headers=m['headers']
    if not isinstance(headers,list) or any(len(h)!=2 or '\n' in h[0]+h[1] or '\r' in h[0]+h[1] for h in headers):
        sys.exit('Error: invalid headers')
    if dict(headers).get('Message-ID')!=mid or dict(headers).get('Thread-ID')!=tid:
        sys.exit('Error: inconsistent message headers')
    (thread/f'{m["seq"]:03d}-{mid}.msg').write_bytes((''.join(f'{k}: {v}\n' for k,v in headers)+'\n'+m['body']).encode())
    if m['seq']<cut:
        (root/'mail'/'.postmaster'/'routed').mkdir(parents=True,exist_ok=True)
        (root/'mail'/'.postmaster'/'routed'/mid).touch()
    for a in m['attachments']:
        name=a['name']
        if not re.fullmatch(r'[A-Za-z0-9_.-]+',name) or name in ('.','..'): sys.exit('Error: invalid attachment name')
        src=pathlib.Path(attach_dir)/name if attach_dir else None
        if src is None or not src.is_file(): missing.append(name); continue
        if src.stat().st_size!=a['bytes']: sys.exit('Error: attachment size mismatch: '+name)
        (thread/'attachments').mkdir(exist_ok=True)
        shutil.copyfile(src,thread/'attachments'/name)
if missing and allow!='1':
    print('Error: missing attachments: '+', '.join(sorted(set(missing))),file=sys.stderr); sys.exit(2)
if missing: print('Warning: missing attachments: '+', '.join(sorted(set(missing))),file=sys.stderr)
for name in {seat}|other:
    seen=root/'mail'/'agents'/name/'seen'; seen.parent.mkdir(parents=True,exist_ok=True)
    seen.write_text(''.join(m['id']+'\n' for m in messages[:cut-1]))
# Only X-Review-Target-Set moves the target; a seat's reply carries X-Review-Target as attribution.
target_message=next((m for m in reversed(messages[:cut]) if dict(m['headers']).get('X-Review-Target-Set')),None)
rt=dict(target_message['headers'])['X-Review-Target-Set'] if target_message else ''
version=dict(target_message['headers']).get('X-Version','1') if target_message else ''
if not rt and no_target!='1':
    print('Error: no review target through cut; use --no-review-target to review project HEAD',file=sys.stderr)
    sys.exit(2)
if rt:
    parts=rt.split()
    if len(parts)!=2: sys.exit('Error: invalid review target')
    branch,sha=parts
    if not re.fullmatch(r'[0-9a-f]{40}',sha): sys.exit('Error: invalid review target')
    dest=root/'mail'/'.postmaster'/'review-target'/f'{tid}.env'; dest.parent.mkdir(parents=True,exist_ok=True)
    dest.write_text(f'BRANCH={branch}\nSHA={sha}\nVERSION={version}\nSET_BY={target_message["from"]}\nSET_AT={target_message["date"]}\n')
else:
    print('Warning: no review target; reviewing --project HEAD',file=sys.stderr)
meta={'thread':tid,'cut':cut,'cut_message_id':trigger['id'],'review_target':rt or None,
      'review_target_seq':target_message['seq'] if target_message else None,
      'missing_attachments':sorted(set(missing)),'other_seats':sorted(other)}
(root/'seed.json').write_text(json.dumps(meta))
PY
python3 - "$work" "$seat" "$model" "$thinking" <<'PY'
import json, pathlib, sys
root=pathlib.Path(sys.argv[1]); seat,model,thinking=sys.argv[2:]
meta=json.loads((root/'seed.json').read_text())
agents={seat:{'backend':'local','model':model,'thinking':thinking,'review-target':'follow'}}
with (root/'config'/'fleet.yaml').open('w') as f:
    f.write('agents:\n')
    for name,fields in agents.items():
        f.write(f'  {name}:\n')
        for k,v in fields.items(): f.write(f'    {k}: {v}\n')
    # A list alias resolves each co-recipient to the one configured seat.
    # Deduplication admits that seat once, even for operator/external mail.
    if meta['other_seats']:
        f.write('lists:\n')
        for name in meta['other_seats']:
            f.write(f'  {name}:\n    members: [{seat}]\n')
PY
if ((resume)); then
    # Only claude's transcript format is understood; another harness would
    # resume something this does not know how to cut.
    persona_harness=$(awk 'NR==1 && $0!="---" {exit} NR>1 && $0=="---" {exit} NR>1 && /^harness:/ {sub(/^harness:[[:space:]]*/,""); print; exit}' "$work/personas/$seat.md")
    [[ -z "$persona_harness" || "$persona_harness" == claude ]] \
        || die "session resume is claude-only; seat '$seat' runs harness '$persona_harness'"
    # The postmaster resumes the id in sessions/<thread>/<seat> from the store
    # in state/<thread>/<seat>/, which the wake binds at ~/.claude/projects.
    # The local wake runs claude in its persistent clone, bound at its own
    # path, so the transcript goes under that directory's project key.
    python3 - "$work" "$seat" "$session_transcript" "$session_id" "$session_cut" <<'PY' || die 'could not seed session'
import datetime, hashlib, json, pathlib, re, shutil, sys
root, seat, source, sid, cut_text = sys.argv[1:]
root = pathlib.Path(root); source = pathlib.Path(source)

def when(text):
    t = datetime.datetime.fromisoformat(text.replace('Z', '+00:00'))
    if t.tzinfo is None:
        raise ValueError('timestamp without a zone: ' + text)
    return t

cut = when(cut_text)

def cut_lines(path):
    """Lines strictly before the cut, as raw bytes, and how many were dropped."""
    lines = path.read_bytes().splitlines(keepends=True)
    kept = None
    for n, line in enumerate(lines, 1):
        if not line.strip():
            stamp = None
        else:
            try:
                entry = json.loads(line)
            except ValueError:
                sys.exit(f'Error: {path}: line {n} is not JSON')
            stamp = entry.get('timestamp') if isinstance(entry, dict) else None
            if stamp is not None:
                try:
                    stamp = when(stamp)
                except (TypeError, ValueError):
                    sys.exit(f'Error: {path}: line {n} has an unreadable timestamp')
        # Entries after the cut may be slightly out of order among
        # themselves (claude stamps them as they are built); only one from
        # before the cut appearing after it makes the cut unsafe.
        if kept is None:
            if stamp is not None and stamp >= cut:
                kept = n - 1
        elif stamp is not None and stamp < cut:
            sys.exit(f'Error: {path}: line {n} is stamped before the cut but follows an entry after it; the cut cannot be trusted')
    if kept is None:
        kept = len(lines)
    return b''.join(lines[:kept]), kept, len(lines) - kept

seed = json.loads((root / 'seed.json').read_text()); tid = seed['thread']
workspace = str(root / 'mail' / '.postmaster' / 'workspaces' / tid / seat)
key = re.sub(r'[^A-Za-z0-9]', '-', workspace)
if len(key) > 200:
    sys.exit('Error: work dir path too long for a claude project key; use a shorter --work-dir')
store = root / 'mail' / '.postmaster' / 'state' / tid / seat
project_dir = store / key; project_dir.mkdir(parents=True)
seeded = project_dir / f'{sid}.jsonl'
data, kept, dropped = cut_lines(source)
seeded.write_bytes(data)
# Subagent transcripts live in a sibling directory named for the session;
# each is cut by the same rule, and anything else in it is copied as is.
sibling = source.with_suffix('')
sibling_jsonl = sibling_other = 0
if sibling.is_dir():
    for path in sorted(sibling.rglob('*')):
        if not path.is_file():
            continue
        dest = project_dir / sid / path.relative_to(sibling)
        dest.parent.mkdir(parents=True, exist_ok=True)
        if path.suffix == '.jsonl':
            dest.write_bytes(cut_lines(path)[0]); sibling_jsonl += 1
        else:
            shutil.copyfile(path, dest); sibling_other += 1
sessions = root / 'mail' / '.postmaster' / 'sessions' / tid
sessions.mkdir(parents=True)
(sessions / seat).write_text(sid + '\n')
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
(root / 'session-seed.json').write_text(json.dumps({
    'session_transcript': str(source), 'session_transcript_sha256': sha(source),
    'seeded_transcript': str(seeded), 'seeded_transcript_sha256': sha(seeded),
    'session_cut': cut_text, 'session_entries_kept': kept, 'session_entries_dropped': dropped,
    'session_subagent_transcripts': sibling_jsonl, 'session_other_files': sibling_other,
    'session_id': sid}))
PY
fi
start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
status=1 reply='' run_dir='' stopped_runs=() stop_failures=()
# shellcheck disable=SC2329 # EXIT trap invokes this function.
record() {
    REPLAY_STATUS=$status REPLAY_REPLY=$reply REPLAY_RUN_DIR=$run_dir REPLAY_START=$start \
    REPLAY_EXPORT=$export_file REPLAY_SEAT=$seat REPLAY_REF=$ref REPLAY_MODEL=$model \
    REPLAY_THINKING=$thinking REPLAY_FORK_REF=$fork_ref REPLAY_OVERLAY=$personas_overlay \
    REPLAY_LAUNCHER=$FORK_SANDBOX_POSTMASTER_LAUNCHER REPLAY_LIVE_CLI=$live_cli_version \
    REPLAY_CREDENTIALS=$claude_credentials \
    REPLAY_STOPPED="$(printf '%s\n' "${stopped_runs[@]}")" \
    REPLAY_STOP_FAILURES="$(printf '%s\n' "${stop_failures[@]}")" \
    REPLAY_OVERLAY_FILES="$(printf '%s\n' "${overlay_files[@]}")" python3 - "$work" <<'PY'
import json,os,pathlib,sys,datetime,hashlib
root=pathlib.Path(sys.argv[1]); data=json.loads((root/'seed.json').read_text())
text_root=root/'text'/'fleet'
hashes={str(p.relative_to(text_root)):hashlib.sha256(p.read_bytes()).hexdigest()
        for section in ('personas','prompts') for p in sorted((text_root/section).glob('*.md'))}
data.update({'export':os.environ['REPLAY_EXPORT'],'seat':os.environ['REPLAY_SEAT'],'personas_ref':os.environ['REPLAY_REF'],
 'model':os.environ['REPLAY_MODEL'],'thinking':os.environ['REPLAY_THINKING'],'fork_sandbox_commit':os.environ['REPLAY_FORK_REF'],
 'start_time':os.environ['REPLAY_START'],'end_time':datetime.datetime.now(datetime.timezone.utc).isoformat(),
 'exit_status':int(os.environ['REPLAY_STATUS']),'run_dir':os.environ['REPLAY_RUN_DIR'],'reply_path':os.environ['REPLAY_REPLY'],
 'personas_overlay':os.environ['REPLAY_OVERLAY'] or None,
 'launcher':os.environ['REPLAY_LAUNCHER'],
 'claude_credentials':os.environ['REPLAY_CREDENTIALS'] or None,
 'stopped_runs':[x for x in os.environ['REPLAY_STOPPED'].splitlines() if x],
 'stop_failures':[x for x in os.environ['REPLAY_STOP_FAILURES'].splitlines() if x],
 'overlaid_files':[x for x in os.environ['REPLAY_OVERLAY_FILES'].splitlines() if x] if os.environ['REPLAY_OVERLAY'] else [],
 'text_sha256':hashes})
records=sorted((root/'mail'/'.postmaster'/'runs').glob('*.env'))
if records:
    rid=records[0].stem
    for key,path in [('handoff',root/'mail'/'.postmaster'/'handoffs'/f'{rid}.md'),
                     ('thread_snapshot',root/'mail'/'.postmaster'/'wake-threads'/rid/'thread.txt')]:
        data[key+'_path']=str(path) if path.is_file() else None
        data[key+'_sha256']=hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None
seed_file=root/'session-seed.json'; check_file=root/'session-check.json'
data.update(json.loads(seed_file.read_text()) if seed_file.is_file() else {'session_transcript':None})
check=json.loads(check_file.read_text()) if check_file.is_file() else {}
data['resumed']=bool(check.get('resumed'))
data['init_session_id']=check.get('init_session_id')
data['cli_version']=check.get('cli_version'); data['cli_version_source']=check.get('cli_version_source')
data['live_cli_version']=os.environ['REPLAY_LIVE_CLI'] or None
(root/'replay.json').write_text(json.dumps(data,indent=2)+'\n')
PY
}
# Reads the wake's init event for the session it actually ran and the CLI
# version it ran under. A claude that cannot resume retries fresh and still
# replies, so only the init line tells a resumed replay from a fresh one.
check_session() {
    local launcher_cli=''
    if command -v claude > /dev/null 2>&1; then
        launcher_cli=$(timeout 10 claude --version 2>/dev/null | awk 'NR==1 {print $1}') || launcher_cli=''
    fi
    python3 - "$work" "${run_dir:+$run_dir/events.jsonl}" "$session_id" "$launcher_cli" "$live_cli_version" <<'PY'
import json, pathlib, sys
root, events, sid, launcher_cli, live = sys.argv[1:]
root = pathlib.Path(root)
init = None
if events and pathlib.Path(events).is_file():
    for line in pathlib.Path(events).read_text(errors='replace').splitlines():
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if isinstance(entry, dict) and entry.get('type') == 'system' and entry.get('subtype') == 'init':
            init = entry
            break
init_sid = init.get('session_id') if init else None
version = init.get('claude_code_version') if init else None
source = 'init' if version else None
if not version and launcher_cli:
    version, source = launcher_cli, 'launcher'
check = {'init_session_id': init_sid, 'resumed': bool(sid) and init_sid == sid,
         'cli_version': version, 'cli_version_source': source}
if live and version != live:
    print(f'Warning: replay ran claude {version or "unknown"}; the live wake ran {live}', file=sys.stderr)
(root / 'session-check.json').write_text(json.dumps(check))
print('1' if check['resumed'] else '0')
PY
}
# shellcheck disable=SC2329 # EXIT trap invokes this function.
cleanup() {
    status=$?
    if (( status != 0 )); then
        local env_file candidate
        for env_file in "$work/mail/.postmaster/runs/"*.env; do
            [[ -f "$env_file" ]] || continue
            candidate=$(sed -n 's/^RUN_DIR=//p' "$env_file")
            [[ -n "$candidate" && ! -f "$candidate/summary.json" ]] || continue
            stopped_runs+=("$candidate")
            if ! "$fork_sandbox/scripts/fork-sandbox" stop "$candidate"; then
                echo "Error: could not stop run $candidate" >&2
                stop_failures+=("$candidate")
            fi
        done
    fi
    record
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
deadline=$((SECONDS+timeout))
while (( SECONDS < deadline )); do
    "$fork_sandbox/scripts/fork-sandbox-postmaster.sh" deliver --project "$project" --once >> "$work/postmaster.log" 2>&1 || die "postmaster failed; see $work/postmaster.log"
    mapfile -t runs < <(find "$work/mail/.postmaster/runs" -maxdepth 1 -name '*.env' -type f 2>/dev/null)
    if ((${#runs[@]} > 1)); then
        for run_record in "${runs[@]}"; do
            second_agent=$(sed -n 's/^AGENT=//p' "$run_record")
            [[ "$second_agent" == "$seat" ]] || die "a second wake is another seat: $second_agent"
        done
        die "a second wake is a retry of seat $seat"
    fi
    if ((${#runs[@]} == 1)); then
        run_dir=$(sed -n 's/^RUN_DIR=//p' "${runs[0]}")
        [[ -n "$run_dir" ]] || die 'run has no directory'
    fi
    mapfile -t replies < <(find "$work/mail/threads" -name '*.msg' -type f | sort)
    if ((${#replies[@]} > cut)); then
        ((${#replies[@]} == cut+1)) || die 'more than one reply harvested'
        reply=${replies[-1]}
        grep -q "^From: @$seat$" "$reply" || die 'reply came from another seat'
        resumed=$(check_session) || die 'could not read the wake events'
        status=0
        echo "$reply"
        if ((resume)) && [[ "$resumed" != 1 ]]; then
            echo "Error: the wake did not resume session $session_id; it started fresh" >&2
            exit 3
        fi
        exit 0
    fi
    sleep 1
done
die "timed out after $timeout seconds; see $work/postmaster.log"
