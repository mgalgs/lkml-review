#!/usr/bin/env bash
set -uo pipefail
repo=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
script=$repo/scripts/lkml-replay.sh
pass=0 fail=0
ok() { printf 'ok %s\n' "$1"; pass=$((pass+1)); }
no() { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }
check() { if "$@"; then ok "$label"; else no "$label"; fi; }
tmp=$(mktemp -d /var/tmp/claude-scratch/lkml-replay-test.XXXXXX)
trap '[[ -z "${KEEP_REPLAY_TEST_TMP:-}" ]] && rm -rf -- "$tmp"' EXIT
export STUB_LOG="$tmp/stub.log" STUB_HANDOFF="$tmp/handoff.md" STUB_RUN_ROOT="$tmp"
export STUB_ENV_LOG="$tmp/stub-env.log" FORK_SANDBOX_MAIL_API_URL='http://invalid.invalid'
export STUB_ARGS_LOG="$tmp/stub-args.log"
cat > "$tmp/launcher" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'wake\n' >> "$STUB_LOG"
printf '%s\n' "$*" >> "$STUB_ARGS_LOG"
printf '%s\t%s\n' "$FORK_SANDBOX_CONFIG_DIR" "${FORK_SANDBOX_MAIL_API_URL-unset}" >> "$STUB_ENV_LOG"
handoff=${!#}
cp "$handoff" "$STUB_HANDOFF"
run=$(mktemp -d "$STUB_RUN_ROOT/run.XXXXXX")
mkdir -p "$run/outbox" "$run/inbox"
if [[ "${STUB_HANG:-}" == 1 ]]; then
    printf '  run dir:  %s\n' "$run"
    exit 0
fi
state='' resume='' clone='' k8s=0
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
    case "${args[i]}" in
        --session-state) state=${args[i+1]};; --resume-session) resume=${args[i+1]};; --clone-dir) clone=${args[i+1]};; --k8s) k8s=1;;
    esac
done
if [[ -n "$resume" ]]; then
    ((k8s)) && clone=/work/clone
    # Resume only what claude would find: the store bound at
    # ~/.claude/projects, under the project key of the wake's working dir.
    key=$(printf '%s' "$clone" | sed 's/[^A-Za-z0-9]/-/g')
    if [[ -f "$state/$key/$resume.jsonl" ]]; then
        cp "$state/$key/$resume.jsonl" "$STUB_RUN_ROOT/resumed.jsonl"
        sid=${STUB_INIT_ID:-$resume}
        if [[ "${STUB_THINKING_DROP:-}" == 1 ]]; then
            printf '%s\n' '{"timestamp":"2026-01-01T00:00:06Z","attachment":{"type":"thinking_drop","newlyDropped":{"reason":"prefix_mismatch","reasonCounts":{"prefix_mismatch":2},"blockCount":2},"secret":"DO-NOT-RECORD"},"message":"DO-NOT-RECORD"}' >> "$state/$key/$resume.jsonl"
        fi
        if [[ "${STUB_TRANSCRIPT_STATE:-}" == missing ]]; then
            rm -- "$state/$key/$resume.jsonl"
        elif [[ "${STUB_TRANSCRIPT_STATE:-}" != unchanged ]]; then
            printf '%s\n' '{"timestamp":"2026-01-01T00:00:07Z","type":"assistant"}' >> "$state/$key/$resume.jsonl"
        fi
    else
        sid=ffffffff-0000-4000-8000-000000000000
    fi
    printf '{"type":"system","subtype":"init","session_id":"%s","claude_code_version":"%s"}\n' "$sid" "${STUB_CLI_VERSION:-9.9.9}" > "$run/events.jsonl"
fi
printf 'Subject: synthetic reply\n\nStub reply.\n' > "$run/outbox/mail-1.md"
printf '0\n' > "$run/exit-code"
printf '{"exit_code":0}\n' > "$run/summary.json"
if [[ -n "${STUB_SECOND_AGENT:-}" ]]; then
    mkdir -p "$FORK_SANDBOX_MAIL_ROOT/.postmaster/runs"
    printf 'AGENT=%s\nRUN_DIR=%s\nRETRY_OF=synthetic\n' "$STUB_SECOND_AGENT" "$run" > "$FORK_SANDBOX_MAIL_ROOT/.postmaster/runs/second.env"
fi
printf '  run dir:  %s\n' "$run"
STUB
chmod +x "$tmp/launcher"
cat > "$tmp/k8s-wake" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
wake=${!#}
mapfile -d '' -t argv < "$wake/fs-argv"
out=$("${argv[@]}")
run=$(sed -n 's/^  run dir:  *//p' <<< "$out" | head -1)
printf '%s' "$run" > "$wake/k8s-run-dir"
cp "$run/exit-code" "$wake/exit-code"
cp "$run/summary.json" "$wake/summary.json"
mkdir -p "$wake/outbox"
cp "$run/outbox/"* "$wake/outbox/"
STUB
chmod +x "$tmp/k8s-wake"
export FORK_SANDBOX_POSTMASTER_LAUNCHER="$tmp/launcher"
sha=$(git -C "$repo" rev-parse HEAD^)
python3 - "$tmp/thread.json" "$sha" <<'PY'
import json,sys
path,sha=sys.argv[1:]
ids=[f'00000000-0000-4000-8000-{i:012d}' for i in (1,2,3,4)]
messages=[]
for i,body in enumerate(('root body','earlier context','cut question','LATER SECRET DEFECT'),1):
    to=['@core','@tests'] if i==3 else ['@core']
    frm='@author'
    h=[['Message-ID',ids[i-1]],['Thread-ID',ids[0]],['Date','Thu, 01 Jan 2026 00:00:00 +0000'],['From',frm],['To',', '.join(to)],['Subject','Synthetic panel'],['X-Hops','8']]
    if i>1: h.append(['In-Reply-To',ids[i-2]])
    if i==3: h.extend([['X-Review-Target-Set','main '+sha],['X-Review-Target','main '+sha],['X-Version','2']])
    messages.append({'seq':i,'id':ids[i-1],'headers':h,'from':frm,'to':to,'cc':[], 'subject':'Synthetic panel','date':'Thu, 01 Jan 2026 00:00:00 +0000','in_reply_to':ids[i-2] if i>1 else None,'body':body+'\n','attachments':[]})
json.dump({'thread':ids[0],'messages':messages,'senders':{},'addressed':[]},open(path,'w'))
PY
old_ref=$(git -C "$repo" log -2 --format=%H -- fleet/personas/core.md | tail -1)
new_ref=$(git -C "$repo" log -1 --format=%H -- fleet/personas/core.md)
[[ -n "$old_ref" && -n "$new_ref" && "$old_ref" != "$new_ref" ]] || { echo 'FAIL distinct persona refs unavailable'; exit 1; }
args=(--export "$tmp/thread.json" --cut 3 --seat core --project "$repo" --model opus --thinking high --timeout 20)
refuse() {
    local expected=$1; shift
    "$script" "$@" > "$tmp/refuse.out" 2>&1
    local rc=$?
    [[ "$rc" == "$expected" ]]
}
sid=0123abcd-0000-4000-8000-000000000001
python3 - "$tmp/live" "$sid" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1]); sid=sys.argv[2]
def entry(ts,text,kind='user'):
    e={'type':kind,'sessionId':sid,'cwd':'/work/clone','message':{'role':kind,'content':text}}
    if ts: e['timestamp']=f'2026-01-01T00:00:{ts}Z'
    return json.dumps(e)+'\n'
(root/sid/'subagents').mkdir(parents=True); (root/sid/'tool-results').mkdir()
(root/f'{sid}.jsonl').write_text(json.dumps({'type':'summary','summary':'MARKER-UNSTAMPED-HEAD'})+'\n'
    +entry('01.000','MARKER-EARLY-NOTE')+entry('04.999','MARKER-CREDENTIAL-READ','assistant')
    +entry('05.000','MARKER-AT-CUT')+json.dumps({'type':'summary','summary':'MARKER-UNSTAMPED-TAIL'})+'\n'
    +entry('09.000','MARKER-AFTER-CUT'))
(root/sid/'subagents'/'agent-a.jsonl').write_text(entry('02.000','MARKER-SUB-EARLY')+entry('06.000','MARKER-SUB-LATE'))
(root/sid/'tool-results'/'r1.txt').write_text('tool output\n')
(root/'disorder.jsonl').write_text(entry('01.000','a')+entry('06.000','b')+entry('04.000','c'))
(root/'jitter.jsonl').write_text(entry('01.000','a')+entry('07.000','b')+entry('06.000','c'))
PY
live=$tmp/live/$sid.jsonl
label='unknown flag refused'; check refuse 2 "${args[@]}" --personas-ref "$new_ref" --bogus
label='missing model refused by name'; check refuse 2 --export "$tmp/thread.json" --cut 3 --seat core --project "$repo" --personas-ref "$new_ref" --thinking high
label='missing model named'; check grep -q -- --model "$tmp/refuse.out"
label='missing thinking refused by name'; check refuse 2 --export "$tmp/thread.json" --cut 3 --seat core --project "$repo" --personas-ref "$new_ref" --model opus
label='missing thinking named'; check grep -q -- --thinking "$tmp/refuse.out"
label='cut beyond export refused'; check refuse 2 --export "$tmp/thread.json" --cut 8 --seat core --personas-ref "$new_ref" --project "$repo" --model opus --thinking high --work-dir "$tmp/beyond"
label='unknown seat refused'; check refuse 2 --export "$tmp/thread.json" --cut 3 --seat absent --personas-ref "$new_ref" --project "$repo" --model opus --thinking high --work-dir "$tmp/absent"
label='unaddressed seat refused'; check refuse 2 --export "$tmp/thread.json" --cut 2 --seat tests --personas-ref "$new_ref" --project "$repo" --model opus --thinking high --work-dir "$tmp/unaddressed"
python3 - "$tmp/thread.json" <<'PY'
import json,sys
p=sys.argv[1];d=json.load(open(p));d['messages'][1]['attachments']=[{'name':'missing.patch','bytes':4}];json.dump(d,open(p,'w'))
PY
for partial in "--session-transcript $live" "--session-id $sid" "--session-cut 2026-01-01T00:00:05Z" "--session-transcript $live --session-id $sid" "--session-id $sid --session-cut 2026-01-01T00:00:05Z"; do
    read -r -a partial_args <<< "$partial"
    label="partial session options refused: $partial"; check refuse 2 "${args[@]}" --personas-ref "$new_ref" "${partial_args[@]}" --work-dir "$tmp/partial"
    label="partial session refusal names the set: $partial"; check grep -q 'go together' "$tmp/refuse.out"
done
label='resume without live CLI version refused'; check refuse 2 "${args[@]}" --personas-ref "$new_ref" --session-transcript "$live" --session-id "$sid" --session-cut 2026-01-01T00:00:05Z --work-dir "$tmp/no-live-cli"
label='resume without live CLI version names the flag'; check grep -q -- '--live-cli-version' "$tmp/refuse.out"
label='non-UTC session cut refused'; check refuse 2 "${args[@]}" --personas-ref "$new_ref" --session-transcript "$live" --session-id "$sid" --session-cut 2026-01-01T00:00:05+02:00 --live-cli-version 9.9.9 --work-dir "$tmp/zone"
label='non-UTC refusal says why'; check grep -q 'ISO-8601 UTC' "$tmp/refuse.out"
label='malformed session id refused'; check refuse 2 "${args[@]}" --personas-ref "$new_ref" --session-transcript "$live" --session-id ../x --session-cut 2026-01-01T00:00:05Z --live-cli-version 9.9.9 --work-dir "$tmp/bad-id"
label='malformed session id refusal says why'; check grep -q 'invalid session id' "$tmp/refuse.out"
printf 'K8S_CONTEXT=fixture\nK8S_NAMESPACE=fixture\nK8S_IMAGE=registry.example/seat:latest\nK8S_PROJECT_IMAGES=repo=registry.example/seat:latest\n' > "$tmp/k8s.env"
label='k8s needs env'; check refuse 2 "${args[@]}" --personas-ref "$new_ref" --k8s --seat-image registry.example/seat:sha-ab12
label='k8s needs image'; check refuse 2 "${args[@]}" --personas-ref "$new_ref" --k8s --k8s-env "$tmp/k8s.env"
label='k8s refuses latest'; check refuse 2 "${args[@]}" --personas-ref "$new_ref" --k8s --k8s-env "$tmp/k8s.env" --seat-image registry.example/seat:latest
label='k8s refuses untagged'; check refuse 2 "${args[@]}" --personas-ref "$new_ref" --k8s --k8s-env "$tmp/k8s.env" --seat-image registry.example/seat
label='missing attachment refused with exit 2 and name'; check refuse 2 "${args[@]}" --personas-ref "$new_ref" --work-dir "$tmp/missing"
label='missing attachment named'; check grep -q missing.patch "$tmp/refuse.out"
python3 - "$tmp/thread.json" <<'PY'
import json,sys
p=sys.argv[1];d=json.load(open(p));d['messages'][1]['attachments']=[];json.dump(d,open(p,'w'))
PY
if [[ -z "${1:-}" ]]; then
    echo 'SKIP postmaster-dependent cases: pass a fork-sandbox checkout as argument'
else
    fs=$(readlink -f "$1")
    for arm in old new; do
        ref=$old_ref; [[ "$arm" == new ]] && ref=$new_ref
        out=$("$script" "${args[@]}" --personas-ref "$ref" --fork-sandbox "$fs" --work-dir "$tmp/$arm" 2> "$tmp/$arm.err")
        rc=$?
        if ((rc)); then cat "$tmp/$arm.err" >&2; fi
        label="$arm replay succeeds"; check test "$rc" -eq 0
        label="$arm reply path is last stdout line"; check test -f "$(tail -1 <<< "$out")"
        label="$arm reply harvested"; check grep -q 'Stub reply' "$out"
        cp "$STUB_HANDOFF" "$tmp/$arm-handoff.md"
        label="$arm handoff contains cut"; check grep -q 'cut question' "$STUB_HANDOFF"
        label="$arm thread snapshot contains prior context"; check grep -q 'earlier context' "$(find "$tmp/$arm/mail/.postmaster/wake-threads" -name thread.txt -print -quit)"
        label="$arm handoff excludes later text"; if grep -q 'LATER SECRET DEFECT' "$STUB_HANDOFF"; then no "$label"; else ok "$label"; fi
        label="$arm only one wake"; check test "$(wc -l < "$STUB_LOG")" -eq "$([[ "$arm" == old ]] && echo 1 || echo 2)"
        label="$arm no flag"; check test ! -e "$tmp/$arm/mail/.postmaster/needs-operator/00000000-0000-4000-8000-000000000001"
        label="$arm three originals plus reply"; check test "$(find "$tmp/$arm/mail/threads/00000000-0000-4000-8000-000000000001" -maxdepth 1 -name '*.msg' | wc -l)" -eq 4
        label="$arm isolated config"; check test -f "$tmp/$arm/config/fleet.yaml"
        label="$arm remote environment removed"; check grep -q "^$tmp/$arm/config[[:space:]]unset$" "$STUB_ENV_LOG"
        label="$arm original store bytes"; check python3 - "$tmp/thread.json" "$tmp/$arm" <<'PY'
import json,pathlib,sys
d=json.load(open(sys.argv[1])); root=pathlib.Path(sys.argv[2])/'mail'/'threads'/d['thread']
for m in d['messages'][:3]:
    expected=(''.join(f'{k}: {v}\n' for k,v in m['headers'])+'\n'+m['body']).encode()
    actual=(root/f'{m["seq"]:03d}-{m["id"]}.msg').read_bytes()
    assert expected==actual
assert len(list(root.glob('*.msg')))==4
PY
        label="$arm record has selected ref and reply"; check python3 - "$tmp/$arm/replay.json" "$ref" "$out" <<'PY'
import hashlib,json,pathlib,sys
d=json.load(open(sys.argv[1])); assert d['personas_ref']==sys.argv[2]
assert d['reply_path']==sys.argv[3] and d['exit_status']==0
assert d['model']=='opus' and d['thinking']=='high'
assert d['launcher']==str(pathlib.Path(sys.argv[1]).parents[1]/'launcher')
assert d['stopped_runs']==[] and d['stop_failures']==[]
assert d['review_target_seq']==3
for key in ('handoff','thread_snapshot'):
    path=pathlib.Path(d[key+'_path'])
    assert path.is_file() and d[key+'_sha256']==hashlib.sha256(path.read_bytes()).hexdigest()
PY
        label="$arm warns about stub launcher"; check grep -q 'nonstandard postmaster launcher' "$tmp/$arm.err"
    done
    label='fresh replays ask for no resume'; check python3 - "$STUB_ARGS_LOG" <<'PY'
import pathlib,sys
lines=pathlib.Path(sys.argv[1]).read_text().splitlines()
assert len(lines)==2 and not any('--resume-session' in l for l in lines)
PY
    label='fresh record says not resumed'; check python3 - "$tmp/new/replay.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d['resumed'] is False and d['session_transcript'] is None and d['exit_status']==0
assert d['faithful'] is None
PY
    "$script" "${args[@]}" --personas-ref "$new_ref" --fork-sandbox "$fs" --live-cli-version 1.2.3 --work-dir "$tmp/fresh-version" > /dev/null 2> "$tmp/fresh-version.err"
    rc=$?
    label='fresh CLI mismatch only warns'; check test "$rc" -eq 0
    label='fresh CLI mismatch warning recorded'; check grep -q 'live wake ran 1.2.3' "$tmp/fresh-version.err"
    "$script" "${args[@]}" --personas-ref "$new_ref" --fork-sandbox "$fs" --work-dir "$tmp/host-prepared" --prepare-only > "$tmp/host-prepared.out"
    rc=$?
    label='host prepare succeeds'; check test "$rc" -eq 0
    label='host prepare launches nothing'; check test ! -e "$tmp/host-prepared/postmaster.log"
    resume_args=(--session-transcript "$live" --session-id "$sid" --session-cut 2026-01-01T00:00:05Z --live-cli-version 9.9.9)
    printf 'credential-fixture-do-not-record' > "$tmp/k8s-credential.json"
    FORK_SANDBOX_POSTMASTER_K8S_WAKE_SCRIPT="$tmp/k8s-wake" FORK_SANDBOX_POSTMASTER_K8S_DETACH=inline \
        "$script" "${args[@]}" --personas-ref "$new_ref" --fork-sandbox "$fs" "${resume_args[@]}" \
        --k8s --k8s-env "$tmp/k8s.env" --seat-image registry.example/seat:sha-ab12 \
        --claude-credentials "$tmp/k8s-credential.json" --work-dir "$tmp/k8s-prepared" --prepare-only > "$tmp/k8s-prepared.out"
    rc=$?
    label='k8s prepare succeeds'; check test "$rc" -eq 0
    label='prepare prints work dir'; check grep -qx "$tmp/k8s-prepared" "$tmp/k8s-prepared.out"
    label='prepare launches nothing'; check test ! -e "$tmp/k8s-prepared/postmaster.log"
    label='k8s prepared files and rekey'; check python3 - "$tmp/k8s-prepared" "$tmp/k8s.env" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1]); d=json.loads((root/'replay.json').read_text())
assert d['prepared'] is True and d['k8s_env']==sys.argv[2] and d['seat_image']=='registry.example/seat:sha-ab12'
assert d['claude_credentials']==str(root.parent/'k8s-credential.json')
assert (root/'config/claude.env').read_text()==f"CLAUDE_CREDENTIALS={d['claude_credentials']}\n"
assert d['thread'][:8]!=d['source_thread'][:8]
assert 'backend: k8s' in (root/'config/fleet.yaml').read_text()
assert 'grant:' not in (root/'config/fleet.yaml').read_text()
config=(root/'config/k8s.env').read_text()
assert 'K8S_IMAGE=registry.example/seat:sha-ab12' in config
assert 'K8S_PROJECT_IMAGES=' in config and ':latest' not in config
assert (root/'mail/.postmaster/state'/d['thread']/'core'/'-work-clone').is_dir()
assert d['thread'][:8] in next(root.glob('mail/threads/*')).name
assert 'MARKER' not in (root/'replay.json').read_text()
assert 'credential-fixture-do-not-record' not in (root/'replay.json').read_text()
PY
    FORK_SANDBOX_POSTMASTER_K8S_WAKE_SCRIPT="$tmp/k8s-wake" FORK_SANDBOX_POSTMASTER_K8S_DETACH=inline \
        "$script" "${args[@]}" --personas-ref "$new_ref" --fork-sandbox "$fs" "${resume_args[@]}" \
        --k8s --k8s-env "$tmp/k8s.env" --seat-image "registry.example/seat@sha256:$(printf 'a%.0s' {1..64})" \
        --work-dir "$tmp/k8s-run" > "$tmp/k8s-run.out" 2> "$tmp/k8s-run.err"
    rc=$?
    label='k8s digest replay succeeds'; check test "$rc" -eq 0
    label='k8s digest replay is faithful'; check python3 - "$tmp/k8s-run/replay.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d['faithful'] is True and d['resumed'] is True
assert d['seat_image'].endswith('a'*64) and d['prepared'] is False
PY
    label='k8s wake branch carries the rekeyed thread'; check python3 - "$tmp/k8s-run" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1]); d=json.loads((root/'replay.json').read_text())
argv=next(root.glob('runs/pm-k8s-wake.*/fs-argv')).read_bytes().split(b'\0')
branch=argv[argv.index(b'--branch')+1].decode()
assert branch.startswith('sbx-mail-'+d['thread'][:8]+'-') and d['source_thread'][:8] not in branch
PY
    for transcript_state in unchanged missing; do
        STUB_TRANSCRIPT_STATE="$transcript_state" FORK_SANDBOX_POSTMASTER_K8S_WAKE_SCRIPT="$tmp/k8s-wake" FORK_SANDBOX_POSTMASTER_K8S_DETACH=inline \
            "$script" "${args[@]}" --personas-ref "$new_ref" --fork-sandbox "$fs" "${resume_args[@]}" \
            --k8s --k8s-env "$tmp/k8s.env" --seat-image registry.example/seat:sha-ab12 \
            --work-dir "$tmp/k8s-$transcript_state" > /dev/null 2> "$tmp/k8s-$transcript_state.err"
        rc=$?
        label="k8s $transcript_state transcript exits 4"; check test "$rc" -eq 4
        label="k8s $transcript_state transcript is unfaithful"; check python3 - "$tmp/k8s-$transcript_state/replay.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d['exit_status']==4 and d['faithful'] is False
assert 'thinking_drop' not in d
PY
    done
    rm -f "$tmp/resumed.jsonl"
    resume_out=$("$script" "${args[@]}" --personas-ref "$new_ref" --fork-sandbox "$fs" "${resume_args[@]}" --live-cli-version 9.9.9 --work-dir "$tmp/resume" 2> "$tmp/resume.err")
    rc=$?
    if ((rc)); then cat "$tmp/resume.err" >&2; fi
    label='resumed replay succeeds'; check test "$rc" -eq 0
    label='resumed reply harvested'; check grep -q 'Stub reply' "$resume_out"
    label='postmaster asks to resume the seeded id'; check grep -q -- "--resume-session $sid" <(tail -1 "$STUB_ARGS_LOG")
    label='seeded session is where the CLI looks, cut strictly before the cut time'; check python3 - "$live" "$tmp/resumed.jsonl" <<'PY'
import pathlib,sys
lines=pathlib.Path(sys.argv[1]).read_bytes().splitlines(keepends=True)
assert pathlib.Path(sys.argv[2]).read_bytes()==b''.join(lines[:3])
PY
    for marker in MARKER-AT-CUT MARKER-UNSTAMPED-TAIL MARKER-AFTER-CUT; do
        label="seeded session lacks $marker"; if grep -q "$marker" "$tmp/resumed.jsonl"; then no "$label"; else ok "$label"; fi
    done
    label='subagent transcripts cut and other files copied'; check python3 - "$tmp/resume" "$sid" <<'PY'
import pathlib,sys
root=pathlib.Path(sys.argv[1]); sid=sys.argv[2]
sub=next(root.glob(f'mail/.postmaster/state/*/core/*/{sid}/subagents/agent-a.jsonl')).read_text()
assert 'MARKER-SUB-EARLY' in sub and 'MARKER-SUB-LATE' not in sub
assert next(root.glob(f'mail/.postmaster/state/*/core/*/{sid}/tool-results/r1.txt')).read_text()=='tool output\n'
PY
    label='resumed record has provenance and no transcript text'; check python3 - "$tmp/resume/replay.json" "$live" "$sid" <<'PY'
import hashlib,json,pathlib,sys
path,live,sid=sys.argv[1:]; text=pathlib.Path(path).read_text(); d=json.loads(text)
sha=lambda p: hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
assert d['exit_status']==0 and d['resumed'] is True and d['session_id']==sid and d['init_session_id']==sid
assert d['faithful'] is True
assert d['session_transcript']==live and d['session_transcript_sha256']==sha(live)
seeded=pathlib.Path(d['seeded_transcript'])
assert seeded.name==sid+'.jsonl'
assert d['seeded_transcript_sha256']==hashlib.sha256(b''.join(pathlib.Path(live).read_bytes().splitlines(keepends=True)[:3])).hexdigest()
assert len(seeded.read_bytes().splitlines())>d['session_entries_kept']
assert d['session_cut']=='2026-01-01T00:00:05Z' and d['session_entries_kept']==3 and d['session_entries_dropped']==3
assert d['cli_version']=='9.9.9' and d['cli_version_source']=='init' and d['live_cli_version']=='9.9.9'
assert 'MARKER' not in text
PY
    label='matching CLI version does not warn'; if grep -q 'live wake ran' "$tmp/resume.err"; then no "$label"; else ok "$label"; fi
    "$script" "${args[@]}" --personas-ref "$new_ref" --fork-sandbox "$fs" "${resume_args[@]}" --live-cli-version 1.2.3 --work-dir "$tmp/resume-version" > /dev/null 2> "$tmp/resume-version.err"
    rc=$?
    label='differing CLI version exits 5'; check test "$rc" -eq 5
    label='differing CLI version warns'; check grep -q 'replay ran claude 9.9.9; the live wake ran 1.2.3' "$tmp/resume-version.err"
    label='differing CLI version records both'; check python3 - "$tmp/resume-version/replay.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d['cli_version']=='9.9.9' and d['live_cli_version']=='1.2.3'
assert d['exit_status']==5 and d['faithful'] is False
assert 'thinking_drop' not in d
PY
    STUB_THINKING_DROP=1 "$script" "${args[@]}" --personas-ref "$new_ref" --fork-sandbox "$fs" "${resume_args[@]}" --work-dir "$tmp/resume-drop" > /dev/null 2> "$tmp/resume-drop.err"
    rc=$?
    label='thinking drop exits 4'; check test "$rc" -eq 4
    label='thinking drop records only metadata'; check python3 - "$tmp/resume-drop/replay.json" <<'PY'
import json,pathlib,sys
text=pathlib.Path(sys.argv[1]).read_text(); d=json.loads(text)
assert d['exit_status']==4 and d['faithful'] is False
assert d['thinking_drop']=={'reason':'prefix_mismatch','reasonCounts':{'prefix_mismatch':2},'blockCount':2}
assert 'DO-NOT-RECORD' not in text
PY
    STUB_INIT_ID=eeeeeeee-0000-4000-8000-000000000000 "$script" "${args[@]}" --personas-ref "$new_ref" --fork-sandbox "$fs" "${resume_args[@]}" --work-dir "$tmp/resume-other" > /dev/null 2> "$tmp/resume-other.err"
    rc=$?
    label='other session id exits 3'; check test "$rc" -eq 3
    label='other session id recorded as not resumed'; check python3 - "$tmp/resume-other/replay.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d['exit_status']==3 and d['resumed'] is False and d['init_session_id']=='eeeeeeee-0000-4000-8000-000000000000'
assert d['reply_path']
PY
    label='other session id named on stderr'; check grep -q 'did not resume session' "$tmp/resume-other.err"
    label='out-of-order transcript refused'; check refuse 2 "${args[@]}" --personas-ref "$new_ref" --fork-sandbox "$fs" --session-transcript "$tmp/live/disorder.jsonl" --session-id "$sid" --session-cut 2026-01-01T00:00:05Z --live-cli-version 9.9.9 --work-dir "$tmp/disorder"
    label='out-of-order refusal says why'; check grep -q 'stamped before the cut but follows' "$tmp/refuse.out"
    "$script" "${args[@]}" --personas-ref "$new_ref" --fork-sandbox "$fs" --session-transcript "$tmp/live/jitter.jsonl" --session-id "$sid" --session-cut 2026-01-01T00:00:05Z --live-cli-version 9.9.9 --work-dir "$tmp/jitter" > /dev/null 2> "$tmp/jitter.err"
    rc=$?
    label='disorder past the cut still resumes'; check test "$rc" -eq 0
    label='disorder past the cut keeps only the early entry'; check python3 - "$tmp/jitter/replay.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d['session_entries_kept']==1 and d['session_entries_dropped']==2
PY
    printf '{}\n' > "$tmp/creds.json"
    "$script" "${args[@]}" --personas-ref "$new_ref" --fork-sandbox "$fs" --claude-credentials "$tmp/creds.json" --work-dir "$tmp/creds" > /dev/null 2> "$tmp/creds.err"
    rc=$?
    label='pinned credential still replies'; check test "$rc" -eq 0
    label='pinned credential written for fork-sandbox'; check grep -qx "CLAUDE_CREDENTIALS=$tmp/creds.json" "$tmp/creds/config/claude.env"
    label='pinned credential recorded'; check python3 - "$tmp/creds/replay.json" "$tmp/creds.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d['claude_credentials']==sys.argv[2]
PY
    label='missing credential file refused'; check refuse 2 "${args[@]}" --personas-ref "$new_ref" --fork-sandbox "$fs" --claude-credentials "$tmp/no-such-creds.json" --work-dir "$tmp/creds-missing"
    mkdir "$tmp/codex-overlay"
    printf -- '---\nharness: codex\nmodel: m\nprotocol: reviewer\n---\n\nA codex core.\n' > "$tmp/codex-overlay/core.md"
    label='resume refused for another harness'; check refuse 2 "${args[@]}" --personas-ref "$new_ref" --fork-sandbox "$fs" --personas-overlay "$tmp/codex-overlay" "${resume_args[@]}" --work-dir "$tmp/codex"
    label='harness refusal names harness'; check grep -q "harness 'codex'" "$tmp/refuse.out"
    label='target differs from project HEAD'; check test "$sha" != "$(git -C "$repo" rev-parse HEAD)"
    label='every wake checks out frozen target'; check python3 - "$STUB_ARGS_LOG" "$sha" <<'PY'
import pathlib,sys
lines=pathlib.Path(sys.argv[1]).read_text().splitlines()
assert lines and all('--checkout '+sys.argv[2] in line for line in lines)
PY
    python3 - "$tmp/thread.json" "$tmp/inherited.json" "$tmp/no-target.json" <<'PY'
import copy,json,sys
d=json.load(open(sys.argv[1]))
inherited=copy.deepcopy(d)
target=dict(d['messages'][2]['headers'])['X-Review-Target-Set']
target_headers=('X-Review-Target-Set','X-Review-Target','X-Version')
inherited['messages'][1]['headers'].extend([['X-Review-Target-Set',target],['X-Review-Target',target],['X-Version','7']])
inherited['messages'][2]['headers']=[h for h in inherited['messages'][2]['headers'] if h[0] not in target_headers]
# A later reply's attribution header names another target and must not move it.
inherited['messages'][2]['headers'].extend([['X-Review-Target','stale '+'0'*40],['X-Version','1']])
json.dump(inherited,open(sys.argv[2],'w'))
none=copy.deepcopy(inherited)
none['messages'][1]['headers']=[h for h in none['messages'][1]['headers'] if h[0] not in target_headers]
json.dump(none,open(sys.argv[3],'w'))
PY
    "$script" "${args[@]}" --export "$tmp/inherited.json" --personas-ref "$new_ref" --fork-sandbox "$fs" --work-dir "$tmp/inherited" > "$tmp/inherited.out" 2> "$tmp/inherited.err"
    label='earlier target and version carried to cut'; check python3 - "$tmp/inherited/replay.json" "$sha" <<'PY'
import json,pathlib,sys
d=json.load(open(sys.argv[1])); root=pathlib.Path(sys.argv[1]).parent
assert d['exit_status']==0 and d['review_target']=='main '+sys.argv[2] and d['review_target_seq']==2
rt=(root/'mail'/'.postmaster'/'review-target'/f'{d["thread"]}.env').read_text()
assert 'VERSION=7\n' in rt and 'SHA='+sys.argv[2]+'\n' in rt
PY
    label='missing target refused without flag'; check refuse 2 "${args[@]}" --export "$tmp/no-target.json" --personas-ref "$new_ref" --fork-sandbox "$fs" --work-dir "$tmp/no-target-refuse"
    label='missing target refusal names flag'; check grep -q -- --no-review-target "$tmp/refuse.out"
    "$script" "${args[@]}" --export "$tmp/no-target.json" --no-review-target --personas-ref "$new_ref" --fork-sandbox "$fs" --work-dir "$tmp/no-target" > "$tmp/no-target.out" 2> "$tmp/no-target.err"
    label='no-target mode records HEAD'; check python3 - "$tmp/no-target/replay.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d['exit_status']==0 and d['review_target'] is None and d['review_target_seq'] is None
PY
    label='no-target mode warns about HEAD'; check grep -q 'reviewing --project HEAD' "$tmp/no-target.err"
    mkdir -p "$tmp/stop-fs/scripts"
    ln -s "$fs/scripts/fork-sandbox-postmaster.sh" "$tmp/stop-fs/scripts/fork-sandbox-postmaster.sh"
    cat > "$tmp/stop-fs/scripts/fork-sandbox" <<'STOP'
#!/usr/bin/env bash
[[ "$1" == stop ]] || exit 2
printf '%s\n' "$2" >> "$STUB_STOP_LOG"
[[ "${STUB_STOP_FAIL:-}" != 1 ]]
STOP
    chmod +x "$tmp/stop-fs/scripts/fork-sandbox"
    export STUB_HANG=1 STUB_STOP_LOG="$tmp/stop.log"
    "$script" "${args[@]}" --timeout 3 --personas-ref "$new_ref" --fork-sandbox "$tmp/stop-fs" --work-dir "$tmp/timeout" > "$tmp/timeout.out" 2> "$tmp/timeout.err"
    timeout_rc=$?
    unset STUB_HANG
    label='hung wake times out nonzero'; check test "$timeout_rc" -ne 0
    label='hung wake stopped and recorded'; check python3 - "$tmp/timeout/replay.json" "$STUB_STOP_LOG" <<'PY'
import json,pathlib,sys
d=json.load(open(sys.argv[1])); stopped=pathlib.Path(sys.argv[2]).read_text().splitlines()
assert len(stopped)==1 and d['stopped_runs']==stopped and d['stop_failures']==[]
PY
    export STUB_HANG=1 STUB_STOP_LOG="$tmp/signal-stop.log"
    "$script" "${args[@]}" --timeout 20 --personas-ref "$new_ref" --fork-sandbox "$tmp/stop-fs" --work-dir "$tmp/signal" > "$tmp/signal.out" 2> "$tmp/signal.err" &
    signal_pid=$!
    for ((i=0; i<100; i++)); do
        compgen -G "$tmp/signal/mail/.postmaster/runs/*.env" > /dev/null && break
        sleep 0.1
    done
    kill -TERM "$signal_pid"
    wait "$signal_pid"
    signal_rc=$?
    unset STUB_HANG
    label='cancelled wake exits for SIGTERM'; check test "$signal_rc" -eq 143
    label='cancelled wake stopped and recorded'; check python3 - "$tmp/signal/replay.json" "$STUB_STOP_LOG" <<'PY'
import json,pathlib,sys
d=json.load(open(sys.argv[1])); stopped=pathlib.Path(sys.argv[2]).read_text().splitlines()
assert len(stopped)==1 and d['stopped_runs']==stopped and d['stop_failures']==[]
assert d['exit_status']==143
PY
    export STUB_STOP_LOG="$tmp/stop.log"
    export STUB_HANG=1 STUB_STOP_FAIL=1
    "$script" "${args[@]}" --timeout 3 --personas-ref "$new_ref" --fork-sandbox "$tmp/stop-fs" --work-dir "$tmp/stop-fail" > "$tmp/stop-fail.out" 2> "$tmp/stop-fail.err"
    stop_fail_rc=$?
    unset STUB_HANG STUB_STOP_FAIL
    label='failed stop preserves timeout status'; check test "$stop_fail_rc" -eq "$timeout_rc"
    label='failed stop reported and recorded'; check python3 - "$tmp/stop-fail/replay.json" "$tmp/stop-fail.err" <<'PY'
import json,pathlib,sys
d=json.load(open(sys.argv[1])); err=pathlib.Path(sys.argv[2]).read_text()
assert len(d['stopped_runs'])==1 and d['stop_failures']==d['stopped_runs']
assert 'could not stop run' in err
PY
    cat > "$tmp/k8s-hang-wake" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == --detach ]]; then
    "$0" "$2" </dev/null >/dev/null 2>&1 &
    exit 0
fi
wake=$1
printf '%s\n' "$$" > "$wake/pid"
printf '%s %s' "$(readlink /proc/self/ns/pid)" "$(cat /proc/sys/kernel/random/boot_id)" > "$wake/pid-identity"
while :; do sleep 1; done
STUB
    cat > "$tmp/k8s-rm" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == rm && "$2" == --branch && -n "${3:-}" ]] || exit 2
printf '%s\n' "$3" >> "$STUB_K8S_RM_LOG"
STUB
    chmod +x "$tmp/k8s-hang-wake" "$tmp/k8s-rm"
    export STUB_K8S_RM_LOG="$tmp/k8s-rm.log"
    FORK_SANDBOX_POSTMASTER_K8S_WAKE_SCRIPT="$tmp/k8s-hang-wake" FORK_SANDBOX_POSTMASTER_K8S="$tmp/k8s-rm" \
        "$script" "${args[@]}" --timeout 3 --personas-ref "$new_ref" --fork-sandbox "$fs" \
        --k8s --k8s-env "$tmp/k8s.env" --seat-image registry.example/seat:sha-ab12 \
        --work-dir "$tmp/k8s-timeout" > "$tmp/k8s-timeout.out" 2> "$tmp/k8s-timeout.err"
    rc=$?
    label='k8s timeout is nonzero'; check test "$rc" -ne 0
    label='k8s timeout uses rm branch contract'; check python3 - "$tmp/k8s-timeout" "$STUB_K8S_RM_LOG" <<'PY'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1]); d=json.loads((root/'replay.json').read_text())
branches=pathlib.Path(sys.argv[2]).read_text().splitlines()
assert len(branches)==1 and branches[0].startswith('sbx-mail-'+d['thread'][:8]+'-')
assert d['source_thread'][:8] not in branches[0]
assert len(d['stopped_runs'])==1 and d['stop_failures']==[]
PY
    k8s_pid=$(cat "$tmp/k8s-timeout/runs/pm-k8s-wake."*/pid)
    label='k8s detached wrapper terminated'; if kill -0 "$k8s_pid" 2>/dev/null && [[ "$(ps -o stat= -p "$k8s_pid" 2>/dev/null)" != Z* ]]; then no "$label"; else ok "$label"; fi
    for second_agent in core tests; do
        export STUB_SECOND_AGENT="$second_agent"
        "$script" "${args[@]}" --personas-ref "$new_ref" --fork-sandbox "$fs" --work-dir "$tmp/second-$second_agent" > "$tmp/second-$second_agent.out" 2> "$tmp/second-$second_agent.err"
        second_rc=$?
        label="second wake $second_agent refused"; check test "$second_rc" -ne 0
        if [[ "$second_agent" == core ]]; then
            label='same-seat second wake called retry'; check grep -q 'a second wake is a retry of seat core' "$tmp/second-core.err"
        else
            label='other-seat second wake named'; check grep -q 'a second wake is another seat: tests' "$tmp/second-tests.err"
        fi
    done
    unset STUB_SECOND_AGENT
    for sender in '@site-ci' '@operator'; do
        python3 - "$tmp/thread.json" "$sender" <<'PY'
import json,sys
p,frm=sys.argv[1:]; d=json.load(open(p)); m=d['messages'][2]
m['from']=frm; m['to']=['@core','@tests','@site-seat']
for h in m['headers']:
    if h[0]=='From': h[1]=frm
    if h[0]=='To': h[1]=', '.join(m['to'])
json.dump(d,open(p,'w'))
PY
        arm=${sender#@}
        before=$(wc -l < "$STUB_LOG")
        "$script" "${args[@]}" --personas-ref "$new_ref" --fork-sandbox "$fs" --work-dir "$tmp/$arm" > "$tmp/$arm.out" 2> "$tmp/$arm.err"
        rc=$?
        if ((rc)); then cat "$tmp/$arm.err" >&2; fi
        label="$arm replay succeeds"; check test "$rc" -eq 0
        label="$arm wakes one seat"; check test "$(wc -l < "$STUB_LOG")" -eq "$((before+1))"
        label="$arm leaves no flag"; check test ! -e "$tmp/$arm/mail/.postmaster/needs-operator/00000000-0000-4000-8000-000000000001"
        label="$arm records one reply"; check test "$(find "$tmp/$arm/mail/threads/00000000-0000-4000-8000-000000000001" -maxdepth 1 -name '*.msg' | wc -l)" -eq 4
    done
    python3 - "$tmp/thread.json" <<'PY'
import json,sys
p=sys.argv[1];d=json.load(open(p));m=d['messages'][2]
m['from']='@author';m['to']=['@core','@tests']
for h in m['headers']:
    if h[0]=='From': h[1]='@author'
    if h[0]=='To': h[1]='@core, @tests'
json.dump(d,open(p,'w'))
PY
    mkdir -p "$tmp/broken-fs/scripts"
    printf '#!/bin/sh\nexit 7\n' > "$tmp/broken-fs/scripts/fork-sandbox-postmaster.sh"
    chmod +x "$tmp/broken-fs/scripts/fork-sandbox-postmaster.sh"
    label='postmaster error exits 2'; check refuse 2 "${args[@]}" --personas-ref "$new_ref" --fork-sandbox "$tmp/broken-fs" --work-dir "$tmp/broken"
    label='failure record matches exit status'; check python3 - "$tmp/broken/replay.json" <<'PY'
import json,sys
assert json.load(open(sys.argv[1]))['exit_status']==2
PY
    label='persona refs produce different handoffs'; if cmp -s "$tmp/old-handoff.md" "$tmp/new-handoff.md"; then no "$label"; else ok "$label"; fi
    label='each handoff contains its ref protocol'; check python3 - "$repo" "$old_ref" "$new_ref" "$tmp" <<'PY'
import pathlib,subprocess,sys
repo,old,new,tmp=sys.argv[1:]; tmp=pathlib.Path(tmp)
for arm,ref in [('old',old),('new',new)]:
    p=subprocess.check_output(['git','-C',repo,'show',ref+':fleet/prompts/protocol-reviewer.md'])
    assert p in (tmp/f'{arm}-handoff.md').read_bytes()
PY
    mkdir "$tmp/overlay"
    cat > "$tmp/overlay/core.md" <<'PERSONA'
---
harness: claude
model: overlay-model
thinking: low
protocol: reviewer
---

Site-only core persona marker.
PERSONA
    cat > "$tmp/overlay/extra.md" <<'PERSONA'
---
harness: claude
model: overlay-model
thinking: low
---

Site-only extra persona.
PERSONA
    overlay_out=$("$script" "${args[@]}" --personas-ref "$new_ref" --fork-sandbox "$fs" --personas-overlay "$tmp/overlay" --work-dir "$tmp/overlay-run" 2> "$tmp/overlay.err")
    rc=$?
    label='overlay replay succeeds'; check test "$rc" -eq 0
    label='overlay persona appears in handoff'; check grep -q 'Site-only core persona marker.' "$STUB_HANDOFF"
    label='ref persona replaced in handoff'; if grep -q 'The Core Reviewer (AI persona)' "$STUB_HANDOFF"; then no "$label"; else ok "$label"; fi
    label='explicit model and thinking override overlay frontmatter'; check python3 - "$tmp/overlay-run/replay.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); assert d['model']=='opus' and d['thinking']=='high'
PY
    label='overlay names and file hashes recorded'; check python3 - "$repo" "$new_ref" "$tmp/overlay-run/replay.json" "$tmp/overlay" <<'PY'
import hashlib,json,pathlib,subprocess,sys
repo,ref,record,overlay=sys.argv[1:]; d=json.load(open(record)); overlay=pathlib.Path(overlay)
assert d['personas_overlay']==str(overlay)
assert d['overlaid_files']==['core.md','extra.md']
for name in ('core.md','extra.md'):
    assert d['text_sha256']['personas/'+name]==hashlib.sha256((overlay/name).read_bytes()).hexdigest()
original=subprocess.check_output(['git','-C',repo,'show',ref+':fleet/personas/tests.md'])
assert d['text_sha256']['personas/tests.md']==hashlib.sha256(original).hexdigest()
prompt=subprocess.check_output(['git','-C',repo,'show',ref+':fleet/prompts/protocol-reviewer.md'])
assert d['text_sha256']['prompts/protocol-reviewer.md']==hashlib.sha256(prompt).hexdigest()
PY
    label='overlay reply harvested'; check grep -q 'Stub reply' "$overlay_out"
    python3 - "$tmp/thread.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d['messages'][1]['attachments']=[{'name':'missing.patch','bytes':4}]
d['messages'][1]['headers'].append(['X-Attachment','attachments/missing.patch'])
json.dump(d,open(p,'w'))
PY
    allow_out=$("$script" "${args[@]}" --personas-ref "$new_ref" --fork-sandbox "$fs" --allow-missing-attachments --work-dir "$tmp/allow" 2> "$tmp/allow.err")
    rc=$?
    label='allow-missing replay succeeds'; check test "$rc" -eq 0
    label='allow-missing warning names file'; check grep -q missing.patch "$tmp/allow.err"
    label='allow-missing record names file'; check python3 - "$tmp/allow/replay.json" <<'PY'
import json,sys
assert json.load(open(sys.argv[1]))['missing_attachments']==['missing.patch']
PY
    mkdir "$tmp/attachments"
    printf 'data' > "$tmp/attachments/missing.patch"
    attached_out=$("$script" "${args[@]}" --personas-ref "$new_ref" --fork-sandbox "$fs" --attachments-dir "$tmp/attachments" --work-dir "$tmp/attached" 2> "$tmp/attached.err")
    rc=$?
    label='attached replay succeeds'; check test "$rc" -eq 0
    label='attachment copied exactly'; check cmp -s "$tmp/attachments/missing.patch" "$tmp/attached/mail/threads/00000000-0000-4000-8000-000000000001/attachments/missing.patch"
    label='attached replay has no missing names'; check python3 - "$tmp/attached/replay.json" <<'PY'
import json,sys
assert json.load(open(sys.argv[1]))['missing_attachments']==[]
PY
    label='attached reply harvested'; check grep -q 'Stub reply' "$attached_out"
    label='allow-missing reply harvested'; check grep -q 'Stub reply' "$allow_out"
fi
printf '%s ok / %s fail\n' "$pass" "$fail"
((fail==0))
