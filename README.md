# gh-download

One GitHub CLI command to download issue and pull request conversations,
attachments, and GitHub Actions logs and annotations.

This extension replaces `gh-comments`, `gh-logs`, and `gh-run-annotations`.
Their functionality is included here; none of those extensions needs to be
installed. The implementation and tests use shell, with no Python dependency.

## Install

From this checkout:

```sh
gh extension install .
```

Requires an authenticated GitHub CLI (`gh`), `jq`, and standard Unix tools.
Conversation attachments also use `curl` and `perl`. Actions workflow archives
use `unzip` with ZIP listing support (the versions shipped with macOS and common
Linux distributions support this).

## Usage

```sh
gh download https://github.com/OWNER/REPO/issues/123
gh download https://github.com/OWNER/REPO/issues/123 tmp/issues
gh download https://github.com/OWNER/REPO/pull/123 tmp/pr-123
gh download https://github.com/OWNER/REPO/actions/runs/123456 tmp/ci-run
gh download https://github.com/OWNER/REPO/actions/runs/123456/job/789 tmp/ci-job
gh download --no-assets https://github.com/OWNER/REPO/issues/123 tmp/issue-123
```

The optional last argument selects the parent directory, defaulting to the
current directory (`.`). Missing parents are created. Relative and absolute
paths are accepted, including paths with spaces.

New downloads create a directory with a descriptive name and a random
six-character suffix. Issue downloads reuse a matching existing export:

- Issues: `REPO-issue-NUMBER-XXXXXX`
- Pull requests: `REPO-pr-NUMBER-XXXXXX`
- Workflow runs: `REPO-run-RUN_ID-XXXXXX`
- Jobs: `REPO-run-RUN_ID-job-JOB_ID-XXXXXX`

For example, the issue command above creates
`tmp/issues/REPO-issue-123-XXXXXX/`. Without the optional
argument, that directory is created under the current directory. The generated
output path is printed on success.

Only `https://github.com` issue, pull request, Actions run, and Actions job URLs
are supported. Query strings, fragments, and a trailing slash are ignored.

## Output

Issues and pull requests produce `README.md`, including the original post,
comments, review summaries, and inline review comments. GitHub-hosted attachments
are saved in `assets/`, with their links rewritten to relative paths. External
attachments are left untouched. Failed attachment downloads retain their remote
links and report a warning. Use `--no-assets` to skip attachment downloads.

Repeating an issue download refreshes its existing export in the selected
parent directory. Matching checks both the `REPO-issue-NUMBER[-SUFFIX]` directory
name and the source URL in `.gh-comments.json`, so repositories with the same
name are kept separate. Newly discovered comments are marked `[NEW]`, and the
metadata retains the comment history. If no match exists, a new directory is
created. If multiple exports match, the command fails; keep only one matching
export in that parent directory before retrying.

Pull request and Actions downloads still create a separate snapshot each time.
Conversation exports include `.gh-comments.json` alongside the Markdown and
attachments.

Workflow runs extract their log archive, preserving job and step filenames.
Job URLs produce `job-JOB_ID.txt`. Both also produce `annotations.json`, a JSON
array of check annotations with `job` and `check_run_id` fields. Workflow
annotations cover the run's jobs; a job URL includes only that job's annotations.
Runs without annotations produce `[]`.

Unrelated files and directories in the parent are preserved. Downloads are
staged before publishing. Failed new downloads remove their staging and output
directories; failed issue refreshes preserve the previous export. Newly created parent directories may
remain after failure. Expired or unavailable Actions logs cause the command to
fail.

## Development

```sh
make test
```

Tests use fake GitHub and attachment responses, without network access. They
also require `zip` to create workflow archive fixtures.

`lib/gh-comments` contains the conversation exporter from the former extension,
with an optional internal output-directory argument. The `lib/gh-logs` helper
downloads Actions logs, and `lib/gh-run-annotations` collects check annotations.
`gh-download` handles URL routing, staging, and publishing exports.
