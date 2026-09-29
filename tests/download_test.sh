#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/gh-download-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/archive"
cat >"$work/bin/gh" <<'EOF'
#!/bin/sh
set -eu
[ "$1" = api ] || exit 99
for arg do
  case $arg in repos/*) endpoint=$arg ;; esac
done
case $endpoint in *"${FAIL_ENDPOINT:-NEVER}"*) exit 1 ;; esac
case $endpoint in
  */issues/*/comments*) printf '%s\n' '[[{"id":'"${COMMENT_ID:-1}"',"body":"A comment","created_at":"2026-09-29","user":{"login":"bob"}}]]' ;;
  */issues/*) printf '%s\n' '{"number":42,"title":"Problem","body":"Description","state":"open","created_at":"2026-09-29","html_url":"https://github.com/acme/widgets/issues/42","user":{"login":"alice"}}' ;;
  */actions/jobs/*/logs) printf 'job output\n' ;;
  */actions/runs/*/logs) cat "$ARCHIVE" ;;
  */actions/jobs/*) printf '%s\n' '{"name":"build","check_run_url":"https://api.github.com/repos/acme/widgets/check-runs/30"}' ;;
  */actions/runs/*/jobs*) printf '%s\n' '[{"jobs":[{"name":"build","check_run_url":"https://api.github.com/repos/acme/widgets/check-runs/30"}]}]' ;;
  */check-runs/30/annotations*) printf '%s\n' '[[{"message":"lint failure"}],[{"message":"second page"}]]' ;;
  *) printf 'unexpected endpoint: %s\n' "$endpoint" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/bin/gh"
PATH="$work/bin:$PATH"
export PATH
cd "$work"
url=https://github.com/acme/widgets
first=$("$root/gh-download" --no-assets "$url/issues/42?x=1#comment" 'nested/foo bar')
case $first in 'nested/foo bar/widgets-issue-42-'??????) ;; *) exit 1 ;; esac
grep -q '# Problem' "$first/README.md"
[ -f "$first/.gh-comments.json" ]
printf 'keep me\n' >'nested/foo bar/notes.txt'
second=$(COMMENT_ID=2 "$root/gh-download" --no-assets "$url/issues/42/" 'nested/foo bar')
[ "$first" = "$second" ]
grep -q '# Problem' "$second/README.md"
grep -q '# Problem' "$first/README.md"
[ "$(cat 'nested/foo bar/notes.txt')" = 'keep me' ]
grep -Fq '[NEW]' "$second/README.md"
jq -e '.previous_fetched_at != null and .new_comment_ids == ["issue_comment:2"]' "$second/.gh-comments.json" >/dev/null
printf 'ok - issue download refreshes the same directory and preserves history\n'

mkdir current
(
  cd current
  printf 'keep me\n' >README.md
  output=$("$root/gh-download" --no-assets "$url/issues/42")
  case $output in ./widgets-issue-42-??????) ;; *) exit 1 ;; esac
  grep -q '# Problem' "$output/README.md"
  [ "$(cat README.md)" = 'keep me' ]
  [ . -ef "$work/current" ]
)
printf 'ok - omitted parent creates a generated directory under current directory\n'

job=$("$root/gh-download" "$url/actions/runs/10/job/20" "$work/jobs/output")
case $job in "$work/jobs/output/widgets-run-10-job-20-"??????) ;; *) exit 1 ;; esac
[ "$(cat "$job/job-20.txt")" = 'job output' ]
jq -e 'length == 2 and .[0].job == "build" and .[0].check_run_id == 30' "$job/annotations.json" >/dev/null
printf 'ok - job logs and annotations under absolute parent\n'

printf 'run output\n' >archive/step.txt
(cd archive && zip -q "$work/logs.zip" step.txt)
ARCHIVE="$work/logs.zip"
export ARCHIVE
run=$("$root/gh-download" "$url/actions/runs/10" runs)
case $run in runs/widgets-run-10-??????) ;; *) exit 1 ;; esac
cmp archive/step.txt "$run/step.txt"
jq -e 'length == 2' "$run/annotations.json" >/dev/null
printf 'ok - workflow archive and annotations in generated directory\n'

assert_empty() {
  for entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [ ! -e "$entry" ] && [ ! -L "$entry" ] || exit 1
  done
}
if FAIL_ENDPOINT=annotations "$root/gh-download" "$url/actions/runs/10" failed/output 2>/dev/null; then exit 1; fi
assert_empty failed/output
if FAIL_ENDPOINT=comments "$root/gh-download" "$url/issues/42" failed/issue 2>/dev/null; then exit 1; fi
assert_empty failed/issue
printf 'ok - failures remove staging and leave no partial export\n'

ln -s /tmp archive/link
(cd archive && zip -qy "$work/unsafe.zip" link)
if ARCHIVE="$work/unsafe.zip" "$root/gh-download" "$url/actions/runs/10" unsafe/output 2>/dev/null; then exit 1; fi
assert_empty unsafe/output
printf 'ok - archive symlinks rejected\n'

printf 'keep me\n' >parent-file
if "$root/gh-download" "$url/issues/42" parent-file 2>/dev/null; then exit 1; fi
[ "$(cat parent-file)" = 'keep me' ]
if "$root/gh-download" 'https://example.com/a/b/issues/1' invalid/output 2>/dev/null; then exit 1; fi
[ ! -e invalid ]
if "$root/gh-download" "$url/issues/42" '' 2>/dev/null; then exit 1; fi
printf 'ok - invalid parents and unsupported URLs rejected\n'

cp "$first/README.md" before-refresh.md
cp "$first/.gh-comments.json" before-refresh.json
if FAIL_ENDPOINT=comments "$root/gh-download" "$url/issues/42" 'nested/foo bar' 2>/dev/null; then exit 1; fi
cmp before-refresh.md "$first/README.md"
cmp before-refresh.json "$first/.gh-comments.json"
printf 'ok - failed refresh preserves the previous export and metadata\n'

cp -R "$first" 'nested/foo bar/widgets-issue-42-other'
jq '.source_url = "https://github.com/another-owner/widgets/issues/42"' \
  "$first/.gh-comments.json" >'nested/foo bar/widgets-issue-42-other/.gh-comments.json'
matched=$("$root/gh-download" --no-assets "$url/issues/42" 'nested/foo bar')
[ "$matched" = "$first" ]
jq -e '.source_url | contains("another-owner")' \
  'nested/foo bar/widgets-issue-42-other/.gh-comments.json' >/dev/null
printf 'ok - matching names from another repository are not refreshed\n'
