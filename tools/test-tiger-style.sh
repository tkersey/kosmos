#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

launcher=$(cd -- "$(dirname -- "$0")" && pwd)/tiger-style.sh
scratch=$(mktemp -d "${TMPDIR:-/tmp}/tiger-style-test.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT
git init --quiet "$scratch/repository"
cd "$scratch/repository"
git config user.name TigerStyle
git config user.email tiger-style@example.invalid
git config commit.gpgsign false
git config core.hooksPath /dev/null

commit_fixture() {
    git add --all
    git commit --quiet -m "$1"
}

expect_failure() {
    local expected=$1
    shift
    if bash "$launcher" "$@" > "$scratch/result" 2>&1; then
        printf 'Expected TigerStyle failure: %s\n' "$expected" >&2
        cat "$scratch/result" >&2
        exit 1
    fi
    if ! grep -Fq -- "$expected" "$scratch/result"; then
        cat "$scratch/result" >&2
        exit 1
    fi
}

expect_success() {
    if ! bash "$launcher" "$@" > "$scratch/result" 2>&1; then
        cat "$scratch/result" >&2
        exit 1
    fi
    grep -Fq 'TigerStyle passed:' "$scratch/result"
}

printf 'fn legacy() void {\n    while (true) {}\n}\n' > legacy.zig
printf 'const value = true;\n' > existing.zig
printf 'const hidden = true;\n' > source.txt
printf '/.zig-cache/\n' > .gitignore
commit_fixture baseline
base=$(git rev-parse HEAD)
expect_failure 'tiger-style/loop-bound'

printf 'const value = false;\n' > existing.zig
commit_fixture unrelated-change
expect_failure 'tiger-style/loop-bound' HEAD

git mv legacy.zig renamed.zig
commit_fixture rename
expect_failure 'tiger-style/loop-bound'

printf 'fn legacy() void {}\n' > renamed.zig
mkdir nested
printf 'const nested = true;\n' > 'nested/space name.zig'
printf 'const dash = true;\n' > --flag.zig
commit_fixture valid
expect_success
expect_success HEAD
valid=$(git rev-parse HEAD)

expect_failure 'requires HEAD to be the requested candidate' "$base"
expect_failure 'Needed a single revision' tiger-style-missing-revision
expect_failure 'Usage:' HEAD HEAD

printf 'const edited = true;\n' >> existing.zig
expect_failure 'requires a clean committed candidate'
git add existing.zig
expect_failure 'requires a clean committed candidate'
git show "$valid:existing.zig" > existing.zig
expect_failure 'requires a clean committed candidate'
git reset --quiet --hard "$valid"

printf 'fn hidden() void {\n    while (true) {}\n}\n' > existing.zig
commit_fixture hidden-committed-violation
git update-index --assume-unchanged existing.zig
printf 'fn hidden() void {}\n' > existing.zig
expect_failure 'tiger-style/loop-bound'
git update-index --no-assume-unchanged existing.zig
git reset --quiet --hard "$valid"

mutate_during_fetch() (
    export replacement=$1
    shift
    git() {
        if [[ " $* " == *' fetch --quiet --depth=1 '* ]]; then
            printf '%s\n' "$replacement" > existing.zig
        fi
        command git "$@"
    }
    export -f git
    "$@"
)

printf 'fn raced() void {\n    while (true) {}\n}\n' > existing.zig
commit_fixture concurrent-committed-violation
mutate_during_fetch 'fn raced() void {}' expect_failure 'tiger-style/loop-bound'
git reset --quiet --hard "$valid"
mutate_during_fetch 'fn raced() void { while (true) {} }' expect_success
git reset --quiet --hard "$valid"

printf 'fn exported() void {\n    while (true) {}\n}\n' > existing.zig
printf 'existing.zig export-ignore export-subst\n' > .gitattributes
commit_fixture export-attributes
expect_failure 'tiger-style/loop-bound'
git reset --quiet --hard "$valid"

git config filter.tiger.clean 'sed "s/harmless();/while (true) {}/"'
git config filter.tiger.smudge 'sed "s/while (true) {}/harmless();/"'
printf 'existing.zig filter=tiger\n' > .gitattributes
printf 'fn filtered() void {\n    harmless();\n}\n' > existing.zig
commit_fixture filtered-committed-violation
expect_failure 'tiger-style/loop-bound'
git reset --quiet --hard "$valid"

printf 'fn bad() void {\n    fail() catch unreachable;\n}\n' >> existing.zig
commit_fixture added-line
expect_failure 'tiger-style/error-handling'
git reset --quiet --hard "$valid"

printf 'fn recurse() void {\n    recurse();\n}\n' > new.zig
commit_fixture new-file
expect_failure 'tiger-style/recursion'
git reset --quiet --hard "$valid"

printf 'fn too_long() void {\n' > existing.zig
for ((line = 0; line < 69; line += 1)); do printf '    _ = 0;\n' >> existing.zig; done
printf '}\n' >> existing.zig
commit_fixture old-long-function
printf 'unrelated\n' > source.txt
commit_fixture unrelated-after-long-function
expect_failure 'tiger-style/function-length'
git reset --quiet --hard "$valid"

printf 'const broken = ;\n' > existing.zig
commit_fixture malformed-source
expect_failure 'tiger-style/syntax'
git reset --quiet --hard "$valid"

printf 'existing.zig -diff\n' > .gitattributes
commit_fixture inherited-binary-classification
expect_failure 'cannot audit a binary-classified Zig file'
git update-index --assume-unchanged .gitattributes
printf '' > .gitattributes
expect_failure 'cannot audit a binary-classified Zig file'
git update-index --no-assume-unchanged .gitattributes
git reset --quiet --hard "$valid"

printf '\0' >> existing.zig
commit_fixture binary-source
expect_failure 'cannot audit a binary-classified Zig file'
git reset --quiet --hard "$valid"

rm existing.zig
ln -s source.txt existing.zig
commit_fixture source-type
expect_failure 'requires regular tracked Zig files'
git reset --quiet --hard "$valid"

git rm --quiet -- '*.zig'
commit_fixture no-source
expect_failure 'requires at least one tracked Zig file'

printf 'TigerStyle integration passed: committed source, concurrent edits, filters, inherited debt, renames, malformed/binary/type rejection, revisions and clean candidates.\n'
