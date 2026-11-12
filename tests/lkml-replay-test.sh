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
