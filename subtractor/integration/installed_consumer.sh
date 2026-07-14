#!/bin/sh

set -eu

root=$(CDPATH= cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/hamlet-subtractor-installed-consumer.XXXXXX")
work=$(CDPATH= cd "$work" && pwd)
prefix="$work/prefix"
consumer="$work/consumer"
trace="$work/resolver.trace"
launcher="$work/with-installed-hamlet-subtractor"
keep_work=${KEEP_WORK:-0}

cleanup() {
  if [ "$keep_work" = 1 ]; then
    printf '%s\n' "preserving installed consumer work directory: $work" >&2
  else
    rm -rf "$work"
  fi
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

json_quote() {
  printf '%s' "$1" | sed 's/[\\"]/\\&/g'
}

require_text() {
  case "$1" in
    *"$2"*) ;;
    *) fail "expected Merlin hover to contain $2" ;;
  esac
}

reject_text() {
  case "$1" in
    *"$2"*) fail "Merlin hover unexpectedly contains $2" ;;
    *) ;;
  esac
}

reject_file_text() {
  if grep -F "$2" "$1" >/dev/null 2>&1; then
    fail "installed consumer source unexpectedly contains $2"
  fi
}

require_one_of() {
  case "$1" in
    *"$2"*|*"$3"*) ;;
    *) fail "expected Merlin hover to contain $2 or $3" ;;
  esac
}

mkdir -p "$prefix" "$consumer"

dune build --display quiet --root "$root" @install
dune install --display quiet --root "$root" --prefix "$prefix"

toolchain_bin=$(dirname "$(command -v dune)")
quoted_toolchain_bin=$(shell_quote "$toolchain_bin")
vscode_dir="$consumer/.vscode"
mkdir -p "$vscode_dir"
quoted_switch=$(json_quote "$root")
quoted_ocamlpath=$(json_quote "$prefix/lib")
cat > "$vscode_dir/settings.json" <<EOF
{
  "ocaml.sandbox": {
    "kind": "opam",
    "switch": "$quoted_switch"
  },
  "ocaml.server.extraEnv": {
    "OCAMLPATH": "$quoted_ocamlpath"
  }
}
EOF

cat > "$launcher" <<EOF
#!/bin/sh
set -eu

if [ "\$#" -eq 0 ]; then
  printf '%s\n' "usage: \$0 COMMAND [ARGUMENT ...]" >&2
  exit 2
fi

work=\$(CDPATH= cd "\$(dirname "\$0")" && pwd)
toolchain_bin=$quoted_toolchain_bin
if [ -n "\$PATH" ]; then
  PATH="\$toolchain_bin:\$PATH"
else
  PATH="\$toolchain_bin"
fi
export PATH

set +u
if [ -n "\$OCAMLPATH" ]; then
  OCAMLPATH="\$work/prefix/lib:\$OCAMLPATH"
else
  OCAMLPATH="\$work/prefix/lib"
fi
set -u
export OCAMLPATH

exec "\$@"
EOF
chmod +x "$launcher"

launcher_ocamlpath=$("$launcher" sh -c 'printf "%s\n" "$OCAMLPATH"')
case "$launcher_ocamlpath" in
  "$prefix/lib"|"$prefix/lib:"*) ;;
  *) fail "installed consumer launcher did not prepend $prefix/lib" ;;
esac

launcher_dune=$(PATH="/usr/bin:/bin" "$launcher" sh -c 'command -v dune')
test "$launcher_dune" = "$toolchain_bin/dune" ||
  fail "installed consumer launcher did not select the build Dune"
test -f "$vscode_dir/settings.json" ||
  fail "installed consumer VS Code settings are missing"

resolver="$prefix/lib/hamlet-subtractor/resolver/hamlet-subtractor-resolver"
test -x "$resolver" || fail "installed resolver is missing at $resolver"
mv "$resolver" "$resolver.real"
cat > "$resolver" <<'EOF'
#!/bin/sh
set -eu
if [ -n "${HAMLET_SUBTRACTOR_RESOLVER_TRACE:-}" ]; then
  printf '%s\n' "$0" >> "$HAMLET_SUBTRACTOR_RESOLVER_TRACE"
fi
exec "$0.real" "$@"
EOF
chmod +x "$resolver"

cat > "$consumer/dune-project" <<'EOF'
(lang dune 3.14)

(using dune_site 0.1)

(name hamlet_installed_consumer)
EOF

cat > "$consumer/dune" <<'EOF'
(executable
 (name main)
 (libraries hamlet)
 (flags
  (:standard -w -32))
 (preprocess
  (staged_pps hamlet-subtractor.ppx)))
EOF

cat > "$consumer/main.ml" <<'EOF'
open Hamlet

[%%hamlet.service
module type Storage = sig
  type missing = [ `Missing of string ]
  type timeout = [ `Timeout of int ]

  val read : unit -> (string, [> missing | timeout ], 'r) t
end]

[%%hamlet.service
module type Logger = sig
  val log : string -> (unit, 'e, 'r) t
end]

[%%hamlet.service
module type Clock = sig
  val now : unit -> (int, 'e, 'r) t
end]

module Logger_live = Logger.Make (struct
  let log _ = Combinators.return ()
end)

module Clock_live = Clock.Make (struct
  let now () = Combinators.return 42
end)

let error_source =
  Combinators.fail (`Missing "gone" : Storage.Errors.error)

let error_effect =
  Combinators.catch error_source ~handler:(fun error ->
      match error with
      | #Storage.Errors.missing -> Combinators.return "recovered"
      | [%hamlet.propagate_e.auto] -> .)

let requirement_source () =
  let open Combinators in
  let* (_ : Logger.Tag.t) = Logger.Tag.summon in
  let* (_ : Clock.Tag.t) = Clock.Tag.summon in
  return "ready"

let requirement_effect =
  Combinators.provide (requirement_source ()) ~handler:(fun requirement ->
      match requirement with
      | #Logger.Tag.r as witness ->
          Logger.Tag.give witness (module Logger_live)
      | [%hamlet.propagate_s.auto] -> .)

let requirement_done : (string, never, never) t =
  Combinators.provide requirement_effect ~handler:(function
    | #Clock.Tag.r as witness -> Clock.Tag.give witness (module Clock_live))

let error_hover = error_effect
let requirement_hover = requirement_effect

let check expected = function
  | Ok actual when String.equal actual expected -> Printf.printf "%s\n" actual
  | Ok actual -> failwith ("unexpected result: " ^ actual)
  | Error _ -> failwith "unexpected typed failure"

let () =
  check "recovered" (Interpreter.run error_effect);
  check "ready" (Interpreter.run requirement_done)
EOF

reject_file_text "$consumer/main.ml" "let error_source :"
reject_file_text "$consumer/main.ml" "let requirement_source () :"

export HAMLET_SUBTRACTOR_RESOLVER_TRACE="$trace"
unset DUNE_DIR_LOCATIONS DUNE_SOURCEROOT

(
  cd "$consumer"
  "$launcher" dune build --display quiet ./main.exe
  "$launcher" dune exec ./main.exe
)

test -s "$trace" || fail "installed resolver was not executed by Dune"
: > "$trace"

error_position=$(awk '/^let error_hover = error_effect$/ {
  print NR ":" (index($0, "error_effect") - 1)
}' "$consumer/main.ml")
requirement_position=$(awk '/^let requirement_hover = requirement_effect$/ {
  print NR ":" (index($0, "requirement_effect") - 1)
}' "$consumer/main.ml")

test -n "$error_position" || fail "error hover position was not found"
test -n "$requirement_position" || fail "requirement hover position was not found"

error_hover=$(
  cd "$consumer"
  "$launcher" ocamlmerlin single type-enclosing -position "$error_position" \
    -index 0 -verbosity 0 -filename main.ml < main.ml
)
requirement_hover=$(
  cd "$consumer"
  "$launcher" ocamlmerlin single type-enclosing \
    -position "$requirement_position" -index 0 -verbosity 0 \
    -filename main.ml < main.ml
)

error_hover_compact=$(printf '%s' "$error_hover" | tr -d '[:space:]')
requirement_hover_compact=$(printf '%s' "$requirement_hover" | tr -d '[:space:]')
require_text "$error_hover_compact" '"class":"return"'
require_text "$requirement_hover_compact" '"class":"return"'
require_one_of "$error_hover" "Timeout" "Storage.Errors.timeout"
reject_text "$error_hover" "Missing"
reject_text "$error_hover" "Storage.Errors.missing"
require_text "$requirement_hover" "Clock"
reject_text "$requirement_hover" "Logger"

test -s "$trace" || fail "installed resolver was not executed by Merlin"
while IFS= read -r executed; do
  case "$executed" in
    "$prefix"/*) ;;
    *) fail "resolver executed outside the temporary prefix: $executed" ;;
  esac
done < "$trace"

printf '%s\n' "installed resolver: ok"
printf '%s\n' "raw Merlin error hover: narrow"
printf '%s\n' "raw Merlin requirement hover: narrow"

if [ "$keep_work" = 1 ]; then
  quoted_launcher=$(shell_quote "$launcher")
  quoted_consumer=$(shell_quote "$consumer")
  quoted_main=$(shell_quote "$consumer/main.ml")
  quoted_work=$(shell_quote "$work")
  shell_script='cd "$1" && exec "${SHELL:-/bin/sh}"'
  quoted_shell_script=$(shell_quote "$shell_script")

  printf '%s\n' "installed consumer work directory: $work"
  printf '%s\n' "consumer project: $consumer"
  printf '%s\n' "installation prefix: $prefix"
  printf '%s\n\n' "environment launcher: $launcher"
  printf '%s\n\n' "the launcher also selects the matching Dune and OCaml toolchain"
  printf '%s\n' "copy a command for a tool already installed on your machine:"
  printf '%s\n' "VS Code (uses the workspace's matching OCaml sandbox):"
  printf '  code --new-window %s\n' "$quoted_consumer"
  printf '%s\n' "Vim:"
  printf '  %s vim %s\n' "$quoted_launcher" "$quoted_main"
  printf '%s\n' "Emacs (quit all running instances and stop any daemon first):"
  printf '  %s emacs %s\n' "$quoted_launcher" "$quoted_main"
  printf '%s\n' "Shell with the private installed packages:"
  printf '  %s sh -c %s sh %s\n' \
    "$quoted_launcher" "$quoted_shell_script" "$quoted_consumer"
  printf '%s\n' "Cleanup (close the editor first, then run):"
  printf '  rm -rf %s\n' "$quoted_work"
fi
