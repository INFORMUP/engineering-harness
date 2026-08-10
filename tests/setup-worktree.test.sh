#!/usr/bin/env bash
# Self-test for template/setup-worktree.sh
#
# Hermetic: each case builds a temp git repo (the "primary" checkout) with a
# populated node_modules, adds a linked worktree, and runs the script from
# inside it. `npm` is stubbed on PATH — the install path must be observable
# without touching the network, and a test that really installed would take
# minutes and prove less.
#
# What matters here is which of two outcomes each package gets: a SYMLINK to
# the primary (fast, and correct only while the checkouts agree) or a REAL
# directory installed in place. Borrowing when they disagree is the bug this
# script exists to prevent — it hands the worktree a generated client built
# from another branch's schema.
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/../template/setup-worktree.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "PASS: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "FAIL: $1 ($2)"; }

git_q() { git -C "$1" "${@:2}" >/dev/null 2>&1; }

# Builds a primary checkout with root+backend packages, a Prisma schema, and a
# node_modules in each; returns the temp root on stdout.
make_primary() {
  local tmp
  tmp="$(mktemp -d)"
  local repo="$tmp/primary"
  mkdir -p "$repo/backend/prisma" "$repo/frontend"

  echo '{"name":"root"}' >"$repo/package.json"
  echo '{"lockfileVersion":3}' >"$repo/package-lock.json"
  echo '{"name":"backend"}' >"$repo/backend/package.json"
  echo '{"lockfileVersion":3}' >"$repo/backend/package-lock.json"
  echo 'model Task { id String @id }' >"$repo/backend/prisma/schema.prisma"
  echo '{"name":"frontend"}' >"$repo/frontend/package.json"

  git_q "$repo" init -b main
  git_q "$repo" config user.email test@example.com
  git_q "$repo" config user.name Test
  git_q "$repo" config commit.gpgsign false
  git_q "$repo" add -A
  git_q "$repo" commit -m base

  # Populated after the commit: node_modules is never tracked.
  mkdir -p "$repo/node_modules/pkg" "$repo/backend/node_modules/pkg" "$repo/frontend/node_modules/pkg"
  echo "$tmp"
}

# Runs the script inside a worktree of the primary, with npm stubbed.
# Prints the script's combined output.
run_in_worktree() {
  local tmp="$1"
  local repo="$tmp/primary" wt="$tmp/wt"

  git_q "$repo" worktree add -b feature "$wt"
  cp "$SCRIPT" "$wt/setup-worktree.sh"
  chmod +x "$wt/setup-worktree.sh"

  # Stub npm: create node_modules the way a real install would, and record it.
  mkdir -p "$tmp/bin"
  cat >"$tmp/bin/npm" <<'STUB'
#!/usr/bin/env bash
mkdir -p node_modules/pkg
echo "STUB-NPM $* in $PWD" >> "$NPM_LOG"
STUB
  chmod +x "$tmp/bin/npm"

  ( cd "$wt" && PATH="$tmp/bin:$PATH" NPM_LOG="$tmp/npm.log" ./setup-worktree.sh 2>&1 )
}

# assert_kind <name> <path> <symlink|dir>
assert_kind() {
  local name="$1" path="$2" want="$3"
  if [[ "$want" == "symlink" ]]; then
    if [[ -L "$path" ]]; then pass "$name"; else fail "$name" "not a symlink: $path"; fi
  else
    if [[ -d "$path" && ! -L "$path" ]]; then pass "$name"; else fail "$name" "not a real dir: $path"; fi
  fi
}

# --- case 1: checkouts agree -> every package borrows -------------------------
tmp="$(make_primary)"
out="$(run_in_worktree "$tmp")"
assert_kind "agreeing checkouts: root symlinks" "$tmp/wt/node_modules" symlink
assert_kind "agreeing checkouts: backend symlinks" "$tmp/wt/backend/node_modules" symlink
if [[ ! -s "$tmp/npm.log" ]]; then
  pass "agreeing checkouts: no install ran"
else
  fail "agreeing checkouts: no install ran" "npm was invoked: $(cat "$tmp/npm.log")"
fi
rm -rf "$tmp"

# --- case 2: schema differs, lockfiles identical -> backend installs ----------
# The case that motivated this: node_modules holds the generated client, so a
# schema-only difference makes borrowing wrong while every manifest matches.
tmp="$(make_primary)"
git_q "$tmp/primary" worktree add -b feature "$tmp/wt"
echo 'model Task { id String @id
  teamSlugs String[] }' >"$tmp/wt/backend/prisma/schema.prisma"
cp "$SCRIPT" "$tmp/wt/setup-worktree.sh"
chmod +x "$tmp/wt/setup-worktree.sh"
mkdir -p "$tmp/bin"
cat >"$tmp/bin/npm" <<'STUB'
#!/usr/bin/env bash
mkdir -p node_modules/pkg
echo "STUB-NPM $* in $PWD" >> "$NPM_LOG"
STUB
chmod +x "$tmp/bin/npm"
out="$( cd "$tmp/wt" && PATH="$tmp/bin:$PATH" NPM_LOG="$tmp/npm.log" ./setup-worktree.sh 2>&1 )"

assert_kind "schema drift: backend installs in place" "$tmp/wt/backend/node_modules" dir
assert_kind "schema drift: root still symlinks" "$tmp/wt/node_modules" symlink
if grep -q "different branch's deps/schema" <<<"$out"; then
  pass "schema drift: says why it installed"
else
  fail "schema drift: says why it installed" "output: $out"
fi
if grep -q "in $tmp/wt/backend\$" "$tmp/npm.log" 2>/dev/null; then
  pass "schema drift: install landed in the worktree, not the primary"
else
  fail "schema drift: install landed in the worktree, not the primary" "$(cat "$tmp/npm.log" 2>/dev/null)"
fi
rm -rf "$tmp"

# --- case 3: a real node_modules already present is never clobbered -----------
tmp="$(make_primary)"
git_q "$tmp/primary" worktree add -b feature "$tmp/wt"
mkdir -p "$tmp/wt/backend/node_modules/deliberate"
cp "$SCRIPT" "$tmp/wt/setup-worktree.sh"
chmod +x "$tmp/wt/setup-worktree.sh"
mkdir -p "$tmp/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$tmp/bin/npm"
chmod +x "$tmp/bin/npm"
( cd "$tmp/wt" && PATH="$tmp/bin:$PATH" NPM_LOG="$tmp/npm.log" ./setup-worktree.sh >/dev/null 2>&1 )
if [[ -d "$tmp/wt/backend/node_modules/deliberate" ]]; then
  pass "existing install: left as-is"
else
  fail "existing install: left as-is" "the deliberate install was replaced"
fi
rm -rf "$tmp"

echo
echo "setup-worktree: $PASS_COUNT passed, $FAIL_COUNT failed"
[[ "$FAIL_COUNT" -eq 0 ]]
