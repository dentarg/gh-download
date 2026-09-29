#!/bin/sh

set -eu

root_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/gh-comments-test.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM

mkdir "$test_dir/bin" "$test_dir/run"

cat >"$test_dir/bin/gh" <<'EOF'
#!/bin/sh
case "$*" in
  *auth\ token*) printf 'test-token\n' ;;
  *issues/42/comments*)
    if [ "${GH_COMMENTS_TEST_REFRESH:-false}" = true ]; then
      printf '%s\n' '[[{"id":101,"body":"A comment with [notes](https://github.com/user-attachments/files/9/notes.txt)","created_at":"2024-01-02T00:00:00Z","html_url":"https://github.test/acme/widgets/issues/42#issuecomment-1","user":{"login":"bob","html_url":"https://github.test/bob"}},{"id":102,"body":"A newly fetched comment","created_at":"2024-01-03T00:00:00Z","html_url":"https://github.test/acme/widgets/issues/42#issuecomment-2","user":{"login":"dave","html_url":"https://github.test/dave"}}]]'
    else
      printf '%s\n' '[[{"id":101,"body":"A comment with [notes](https://github.com/user-attachments/files/9/notes.txt)","created_at":"2024-01-02T00:00:00Z","html_url":"https://github.test/acme/widgets/issues/42#issuecomment-1","user":{"login":"bob","html_url":"https://github.test/bob"}}]]'
    fi
    ;;
  *issues/42*)
    printf '%s\n' '{"number":42,"title":"Broken widget","body":"Screenshot: ![failure](https://github.com/user-attachments/assets/image-id)","state":"open","created_at":"2024-01-01T00:00:00Z","html_url":"https://github.test/acme/widgets/issues/42","user":{"login":"alice","html_url":"https://github.test/alice"}}'
    ;;
  *issues/7/comments*) printf '%s\n' '[[ ]]' ;;
  *issues/7*)
    printf '%s\n' '{"number":7,"title":"Improve widget","body":"Ready for review","state":"closed","created_at":"2024-02-01T00:00:00Z","html_url":"https://github.test/acme/widgets/pull/7","pull_request":{},"user":{"login":"alice","html_url":"https://github.test/alice"}}'
    ;;
  *pulls/7/reviews*)
    printf '%s\n' '[[{"id":201,"body":"Looks good","state":"APPROVED","submitted_at":"2024-02-02T00:00:00Z","html_url":"https://github.test/acme/widgets/pull/7#review-1","user":{"login":"bob","html_url":"https://github.test/bob"}}]]'
    ;;
  *pulls/7/comments*)
    printf '%s\n' '[[{"id":301,"body":"Please rename this","path":"widget.c","line":12,"created_at":"2024-02-03T00:00:00Z","html_url":"https://github.test/acme/widgets/pull/7#discussion-1","user":{"login":"carol","html_url":"https://github.test/carol"}}]]'
    ;;
  *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 1 ;;
esac
EOF

cat >"$test_dir/bin/curl" <<'EOF'
#!/bin/sh
for argument do
  if [ "$previous" = --output ]; then output=$argument; fi
  previous=$argument
done
printf 'downloaded' >"$output"
EOF

chmod +x "$test_dir/bin/gh" "$test_dir/bin/curl"

(
  cd "$test_dir/run"
  PATH="$test_dir/bin:$PATH" "$root_dir/lib/gh-comments" \
    https://github.test/acme/widgets/issues/42 >/dev/null 2>log
)

markdown="$test_dir/run/widgets-issue-42/README.md"
[ -f "$markdown" ]
[ -f "$test_dir/run/widgets-issue-42/.gh-comments.json" ]
[ -f "$test_dir/run/widgets-issue-42/assets/001-image-id" ]
[ -f "$test_dir/run/widgets-issue-42/assets/002-notes.txt" ]
grep -F '# Broken widget' "$markdown" >/dev/null
grep -F 'assets/001-image-id' "$markdown" >/dev/null
grep -F 'assets/002-notes.txt' "$markdown" >/dev/null
grep -F '### [@bob](https://github.test/bob) · 2024-01-02T00:00:00Z' "$markdown" >/dev/null
grep -F 'path="widgets-issue-42" assets=2' "$test_dir/run/log" >/dev/null

printf 'ok - exports an issue, comments, and assets\n'

(
  cd "$test_dir/run"
  GH_COMMENTS_TEST_REFRESH=true PATH="$test_dir/bin:$PATH" \
    "$root_dir/lib/gh-comments" \
    https://github.test/acme/widgets/issues/42 >/dev/null 2>refresh-log
)

state="$test_dir/run/widgets-issue-42/.gh-comments.json"
grep -F '> **1 new comment since ' "$markdown" >/dev/null
grep -F '### [NEW] [@dave](https://github.test/dave)' "$markdown" >/dev/null
grep -F 'A newly fetched comment' "$markdown" >/dev/null
jq -e '.new_comment_ids == ["issue_comment:102"]' "$state" >/dev/null
grep -F 'new_comments=1 refreshed=true' \
  "$test_dir/run/refresh-log" >/dev/null

printf 'ok - marks comments discovered during a refresh\n'

(
  cd "$test_dir/run"
  GH_COMMENTS_TEST_REFRESH=true PATH="$test_dir/bin:$PATH" \
    "$root_dir/lib/gh-comments" \
    https://github.test/acme/widgets/issues/42 >/dev/null 2>unchanged-log
)

grep -F '> **0 new comments since ' "$markdown" >/dev/null
if grep -F '### [NEW] ' "$markdown" >/dev/null; then
  printf 'stale new-comment marker remained after refresh\n' >&2
  exit 1
fi
jq -e '.new_comment_ids == []' "$state" >/dev/null

printf 'ok - clears new markers on an unchanged refresh\n'

(
  cd "$test_dir/run"
  PATH="$test_dir/bin:$PATH" "$root_dir/lib/gh-comments" --no-assets \
    https://github.test/acme/widgets/pull/7 >/dev/null 2>pr-log
)

markdown="$test_dir/run/widgets-pr-7/README.md"
grep -F '> **Pull request #7**' "$markdown" >/dev/null
grep -F '### Review (APPROVED) by [@bob](https://github.test/bob)' \
  "$markdown" >/dev/null
grep -F '### Inline review comment by [@carol](https://github.test/carol)' \
  "$markdown" >/dev/null
# The backticks are literal Markdown, not shell command substitution.
# shellcheck disable=SC2016
grep -F 'On `widget.c`:12' "$markdown" >/dev/null

printf 'ok - exports pull request reviews and inline comments\n'
