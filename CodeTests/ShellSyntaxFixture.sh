#!/usr/bin/env bash
# Shell syntax highlighting fixture.
# Includes quote forms, expansions, redirects, loops, case, heredocs, and traps.

set -euo pipefail

readonly APP_NAME='Code Preview'
readonly BUILD_DIR="${TMPDIR:-/tmp}/code-fixture"
readonly SINGLE_QUOTED='literal $HOME `date` "double" text'
readonly DOUBLE_QUOTED="expanded home=${HOME:-unknown} app=${APP_NAME}"
readonly ANSI_C_QUOTED=$'tab\tnewline\nsingle quote: \''
readonly ESCAPED_QUOTES="quote: \" backslash: \\ dollar: \$ backtick: \`"
readonly COMMAND_SUBSTITUTION="$(printf '%s' "inside command substitution")"
readonly NESTED_SUBSTITUTION="$(basename "$(pwd)")"
readonly ARITHMETIC_RESULT="$((2 + 3 * 4))"

paths=(
  "/Applications/Code.app"
  "$HOME/Library/Application Support/Code"
  "${BUILD_DIR}/output file.txt"
)

declare -A labels=(
  [single]="single quoted"
  [double]="double quoted"
  [ansi]="ansi-c quoted"
)

log() {
  local level="$1"
  shift
  printf '[%s] %s\n' "$level" "$*"
}

cleanup() {
  rm -rf -- "$BUILD_DIR"
}
trap cleanup EXIT INT TERM

mkdir -p -- "$BUILD_DIR"

if [[ "${1:-}" == "--dry-run" ]]; then
  log INFO "dry run for ${APP_NAME}"
elif [[ "${1:-}" =~ ^--[a-z-]+$ ]]; then
  log WARN "unknown option: ${1}"
else
  log INFO "normal mode"
fi

for path in "${paths[@]}"; do
  case "$path" in
    *.app)
      log APP "bundle path: $path"
      ;;
    *"Application Support"*)
      log DATA "support path: $path"
      ;;
    *)
      log FILE "plain path: $path"
      ;;
  esac
done

while IFS= read -r line; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  log LINE "$line"
done <<'SINGLE_QUOTED_HEREDOC'
# This heredoc is single quoted.
$HOME should stay literal here.
Backticks `date` should stay literal here.
SINGLE_QUOTED_HEREDOC

cat >"${BUILD_DIR}/expanded.txt" <<EXPANDED_HEREDOC
This heredoc expands variables.
app=${APP_NAME}
build_dir=${BUILD_DIR}
EXPANDED_HEREDOC

cat <<-TABBED_HEREDOC
	Tabbed heredoc strips leading tabs.
	command substitution: ${COMMAND_SUBSTITUTION}
TABBED_HEREDOC

printf '%s\n' \
  "$SINGLE_QUOTED" \
  "$DOUBLE_QUOTED" \
  "$ANSI_C_QUOTED" \
  "$ESCAPED_QUOTES" \
  "$NESTED_SUBSTITUTION" \
  "$ARITHMETIC_RESULT" \
  | sed -E 's/[[:space:]]+/ /g' \
  >"${BUILD_DIR}/quotes.txt"

if grep -Eq 'quote|home|app' "${BUILD_DIR}/quotes.txt"; then
  log INFO "regex matched generated quote output"
fi

mapfile -t generated_lines < <(find "$BUILD_DIR" -type f -maxdepth 1 | sort)
for generated in "${generated_lines[@]}"; do
  [[ -f "$generated" ]] || continue
  log GENERATED "$(basename "$generated")"
done

(
  cd "$BUILD_DIR"
  printf 'subshell pwd=%s\n' "$PWD" >>subshell.log
)

log DONE "fixture complete"
