#!/usr/bin/env bash
# Replay one fleet seat through fork-sandbox's local postmaster.
set -euo pipefail

usage() { echo 'Usage: lkml-replay.sh --export JSON --cut SEQ --seat NAME --personas-ref SHA --project DIR --model M --thinking T [--personas-overlay DIR] [--no-review-target] [--attachments-dir DIR] [--allow-missing-attachments] [--fork-sandbox DIR] [--work-dir DIR] [--timeout SECONDS]'; }
die() { echo "Error: $*" >&2; exit 2; }
repo=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
export_file='' cut='' seat='' ref='' project='' model='' thinking='' attachments_dir='' personas_overlay='' fork_sandbox='' work='' timeout=3600 allow_missing=0 no_review_target=0
while (($#)); do
    case "$1" in
        --export|--cut|--seat|--personas-ref|--project|--model|--thinking|--attachments-dir|--personas-overlay|--fork-sandbox|--work-dir|--timeout)
            (($# >= 2)) || die "$1 requires a value"
            case "$1" in
                --export) export_file=$2;; --cut) cut=$2;; --seat) seat=$2;; --personas-ref) ref=$2;; --project) project=$2;;
                --model) model=$2;; --thinking) thinking=$2;; --attachments-dir) attachments_dir=$2;;
                --personas-overlay) personas_overlay=$2;;
                --fork-sandbox) fork_sandbox=$2;; --work-dir) work=$2;; --timeout) timeout=$2;;
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
[[ -z "$attachments_dir" ]] || attachments_dir=$(readlink -f "$attachments_dir")
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
start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
status=1 reply='' run_dir='' stopped_runs=() stop_failures=()
# shellcheck disable=SC2329 # EXIT trap invokes this function.
record() {
    REPLAY_STATUS=$status REPLAY_REPLY=$reply REPLAY_RUN_DIR=$run_dir REPLAY_START=$start \
    REPLAY_EXPORT=$export_file REPLAY_SEAT=$seat REPLAY_REF=$ref REPLAY_MODEL=$model \
    REPLAY_THINKING=$thinking REPLAY_FORK_REF=$fork_ref REPLAY_OVERLAY=$personas_overlay \
    REPLAY_LAUNCHER=$FORK_SANDBOX_POSTMASTER_LAUNCHER \
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
(root/'replay.json').write_text(json.dumps(data,indent=2)+'\n')
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
        status=0
        echo "$reply"
        exit 0
    fi
    sleep 1
done
die "timed out after $timeout seconds; see $work/postmaster.log"
