#!/bin/sh

set -eu

root=${HAMLET_SUBTRACTOR_SOURCE_ROOT:-}
if [ -z "$root" ]; then
  root=$(CDPATH= cd "$(dirname "$0")" && pwd)
fi
while :; do
  case "$root" in
    */_build/*) ;;
    *)
      if [ -f "$root/dune-project" ]; then
        break
      fi
      ;;
  esac
  parent=$(dirname "$root")
  if [ "$parent" = "$root" ]; then
    printf '%s\n' 'cannot locate the hamlet-subtractor source root' >&2
    exit 1
  fi
  root=$parent
done
root=$(CDPATH= cd "$root" && pwd)

work=$(mktemp -d "${TMPDIR:-/tmp}/hamlet-subtractor-installed-consumer.XXXXXX")
work=$(CDPATH= cd "$work" && pwd)
prefix="$work/prefix"
consumer="$work/consumer"
trace="$work/resolver.trace"
launcher="$work/with-installed-hamlet-subtractor"
keep_work=${KEEP_WORK:-0}
build_source=

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

if [ "${HAMLET_SUBTRACTOR_DUNE_ACTION:-}" = 1 ]; then
  build_source=$work/source
  mkdir -p "$build_source"
  (
    cd "$root"
    tar -cf - \
      --exclude='./.git' \
      --exclude='./_build' \
      --exclude='./_opam' \
      --exclude='./.qmd' \
      --exclude='./knowledge' \
      --exclude='./knowledge-backup-*' \
      .
  ) | (
    cd "$build_source"
    tar -xf -
  )
  (
    cd "$build_source"
    dune build --display quiet @install
    dune install --display quiet --prefix "$prefix"
  )
else
  dune build --display quiet --root "$root" @install
  dune install --display quiet --root "$root" --prefix "$prefix"
fi

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

cat > "$consumer/services.ml" <<'EOF'
open Hamlet

[%%hamlet.service
module type Logger = sig
  val log : string -> (unit, 'e, 'r) t
end]

[%%hamlet.service
module type Clock = sig
  val now : unit -> (int, 'e, 'r) t
end]

[%%hamlet.service
module type Metrics = sig
  val increment : string -> (unit, 'e, 'r) t
end]

[%%hamlet.service
module type Audit = sig
  val record : string -> (unit, 'e, 'r) t
end]

module Logger_live = Logger.Make (struct
  let log _ = Combinators.return ()
end)

module Clock_live = Clock.Make (struct
  let now () = Combinators.return 42
end)

module Metrics_live = Metrics.Make (struct
  let increment _ = Combinators.return ()
end)

module Audit_live = Audit.Make (struct
  let record _ = Combinators.return ()
end)
EOF

cat > "$consumer/error_helpers.ml" <<'EOF'
open Hamlet
open Services

let[@hamlet.generic] recover_missing source =
  Combinators.catch source ~handler:(function
    | `Missing -> Combinators.return "generic missing"
    | [%hamlet.propagate_e.auto] -> .)

let[@hamlet.generic] recover_missing_and_timeout source =
  Combinators.catch
    (recover_missing source)
    ~handler:(function
      | `Timeout -> Combinators.return "generic timeout"
      | [%hamlet.propagate_e.auto] -> .)

let[@hamlet.generic] recover_layer_missing source =
  Layer.catch source ~handler:(function
    | `Missing ->
        Layer.make Logger.Tag.key
          (Combinators.return (module Logger_live : Logger.S))
    | [%hamlet.propagate_e.auto] -> .)
EOF

cat > "$consumer/requirement_helpers.ml" <<'EOF'
open Hamlet
open Services

let[@hamlet.generic] provide_logger source =
  Combinators.provide source ~handler:(function
    | #Logger.Tag.r as witness -> Logger.Tag.give witness (module Logger_live)
    | [%hamlet.propagate_s.auto] -> .)

let[@hamlet.generic] provide_logger_and_clock source =
  Combinators.provide
    (provide_logger source)
    ~handler:(function
      | #Clock.Tag.r as witness -> Clock.Tag.give witness (module Clock_live)
      | [%hamlet.propagate_s.auto] -> .)

let logger_layer =
  Layer.make Logger.Tag.key
    (Combinators.return (module Logger_live : Logger.S))

let[@hamlet.generic] provide_logger_layer target =
  Layer.provide_to_effect ~source:logger_layer
    ~handler:(fun logger -> function
      | #Logger.Tag.r as witness -> Logger.Tag.give witness logger
      | [%hamlet.propagate_s.auto] -> .)
    target
EOF

cat > "$consumer/main.ml" <<'EOF'
open Hamlet
open Services

module Errors = struct
  type offline = [ `Offline ]
  type denied = [ `Denied ]
end

let error_source =
  if Sys.opaque_identity true then Combinators.fail `Missing
  else if Sys.opaque_identity true then Combinators.fail `Timeout
  else if Sys.opaque_identity true then Combinators.fail `Offline
  else Combinators.fail `Denied

let generic_error_effect =
  Error_helpers.recover_missing_and_timeout error_source

let error_after_offline =
  Combinators.catch
    (Error_helpers.recover_missing_and_timeout error_source)
    ~handler:(function
    | #Errors.offline -> Combinators.return "handled offline"
    | [%hamlet.propagate_e.auto] -> .)

let error_done =
  Combinators.catch error_after_offline ~handler:(function
    | #Errors.denied -> Combinators.return "handled denied")

let layer_source =
  Layer.make Logger.Tag.key
    (match Sys.opaque_identity 2 with
    | 0 -> Combinators.fail `Missing
    | 1 -> Combinators.fail `Offline
    | _ -> Combinators.fail `Denied)

let layer_after_offline =
  Error_helpers.recover_layer_missing layer_source
  |> Layer.catch ~handler:(function
       | #Errors.offline ->
           Layer.make Logger.Tag.key
             (Combinators.return (module Logger_live : Logger.S))
       | [%hamlet.propagate_e.auto] -> .)

let layer_error_effect =
  let target =
    let open Combinators in
    let* _logger = Logger.Tag.summon in
    return "layer ready"
  in
  Layer.provide_to_effect ~source:layer_after_offline
    ~handler:(fun logger -> function
      | #Logger.Tag.r as witness -> Logger.Tag.give witness logger)
    target

let layer_error_done =
  Combinators.catch layer_error_effect ~handler:(function
    | #Errors.denied -> Combinators.return "layer denied")

let requirement_source =
  let open Combinators in
  let* (module Logger) = Logger.Tag.summon in
  let* () = Logger.log "request started" in
  let* (module Clock) = Clock.Tag.summon in
  let* now = Clock.now () in
  let* (module Metrics) = Metrics.Tag.summon in
  let* () = Metrics.increment "request.ready" in
  let* (module Audit) = Audit.Tag.summon in
  let* () = Audit.record "request completed" in
  return (Printf.sprintf "ready at %d" now)

let generic_requirement_effect =
  Requirement_helpers.provide_logger_and_clock requirement_source

let requirement_after_metrics =
  Combinators.provide
    (Requirement_helpers.provide_logger_and_clock requirement_source)
    ~handler:(function
    | #Metrics.Tag.r as witness ->
        Metrics.Tag.give witness (module Metrics_live)
    | [%hamlet.propagate_s.auto] -> .)

let requirement_done =
  Combinators.provide requirement_after_metrics ~handler:(function
    | #Audit.Tag.r as witness -> Audit.Tag.give witness (module Audit_live))

let layer_provider_target =
  let open Combinators in
  let* _logger = Logger.Tag.summon in
  let* _clock = Clock.Tag.summon in
  return "layer provider ready"

let layer_provider_effect =
  Requirement_helpers.provide_logger_layer layer_provider_target

let layer_provider_done =
  Combinators.provide layer_provider_effect ~handler:(function
    | #Clock.Tag.r as witness -> Clock.Tag.give witness (module Clock_live))

let generic_error_hover = generic_error_effect
let error_after_offline_hover = error_after_offline
let layer_after_offline_hover = layer_after_offline
let generic_requirement_hover = generic_requirement_effect
let requirement_after_metrics_hover = requirement_after_metrics
let layer_provider_hover = layer_provider_effect

let check expected = function
  | Ok actual when String.equal actual expected -> Printf.printf "%s\n" actual
  | Ok actual -> failwith ("unexpected result: " ^ actual)
  | Error _ -> failwith "unexpected typed failure"

let () =
  check "generic missing" (Interpreter.run error_done);
  check "layer denied" (Interpreter.run layer_error_done);
  check "ready at 42" (Interpreter.run requirement_done);
  check "layer provider ready" (Interpreter.run layer_provider_done)
EOF

reject_file_text "$consumer/main.ml" "let error_source :"
reject_file_text "$consumer/main.ml" "let requirement_source :"
reject_file_text "$consumer/main.ml" "let requirement_done :"
reject_file_text "$consumer/main.ml" ":>"
reject_file_text "$consumer/error_helpers.ml" "[%hamlet.forward.auto]"
reject_file_text "$consumer/requirement_helpers.ml" "[%hamlet.forward.auto]"

export HAMLET_SUBTRACTOR_RESOLVER_TRACE="$trace"
unset DUNE_DIR_LOCATIONS DUNE_SOURCEROOT

(
  cd "$consumer"
  "$launcher" dune build --display quiet ./main.exe
  "$launcher" dune exec ./main.exe
)

test -s "$trace" || fail "installed resolver was not executed by Dune"
: > "$trace"

generic_error_position=$(awk '/^let generic_error_hover = generic_error_effect$/ {
  print NR ":" (index($0, "generic_error_effect") - 1)
}' "$consumer/main.ml")
error_after_offline_position=$(awk '/^let error_after_offline_hover = error_after_offline$/ {
  print NR ":" (index($0, "error_after_offline") - 1)
}' "$consumer/main.ml")
layer_after_offline_position=$(awk '/^let layer_after_offline_hover = layer_after_offline$/ {
  print NR ":" (index($0, "layer_after_offline") - 1)
}' "$consumer/main.ml")
generic_requirement_position=$(awk '/^let generic_requirement_hover = generic_requirement_effect$/ {
  print NR ":" (index($0, "generic_requirement_effect") - 1)
}' "$consumer/main.ml")
requirement_after_metrics_position=$(awk '/^let requirement_after_metrics_hover = requirement_after_metrics$/ {
  print NR ":" (index($0, "requirement_after_metrics") - 1)
}' "$consumer/main.ml")
layer_provider_position=$(awk '/^let layer_provider_hover = layer_provider_effect$/ {
  print NR ":" (index($0, "layer_provider_effect") - 1)
}' "$consumer/main.ml")

test -n "$generic_error_position" || fail "generic error hover position was not found"
test -n "$error_after_offline_position" || fail "offline error hover position was not found"
test -n "$layer_after_offline_position" || fail "layer error hover position was not found"
test -n "$generic_requirement_position" || fail "generic requirement hover position was not found"
test -n "$requirement_after_metrics_position" || fail "metrics requirement hover position was not found"
test -n "$layer_provider_position" || fail "layer provider hover position was not found"

generic_error_hover=$(
  cd "$consumer"
  "$launcher" ocamlmerlin single type-enclosing -position "$generic_error_position" \
    -index 0 -verbosity 0 -filename main.ml < main.ml
)
error_after_offline_hover=$(
  cd "$consumer"
  "$launcher" ocamlmerlin single type-enclosing -position "$error_after_offline_position" \
    -index 0 -verbosity 0 -filename main.ml < main.ml
)
layer_after_offline_hover=$(
  cd "$consumer"
  "$launcher" ocamlmerlin single type-enclosing -position "$layer_after_offline_position" \
    -index 0 -verbosity 0 -filename main.ml < main.ml
)
generic_requirement_hover=$(
  cd "$consumer"
  "$launcher" ocamlmerlin single type-enclosing \
    -position "$generic_requirement_position" -index 0 -verbosity 0 \
    -filename main.ml < main.ml
)
requirement_after_metrics_hover=$(
  cd "$consumer"
  "$launcher" ocamlmerlin single type-enclosing \
    -position "$requirement_after_metrics_position" -index 0 -verbosity 0 \
    -filename main.ml < main.ml
)
layer_provider_hover=$(
  cd "$consumer"
  "$launcher" ocamlmerlin single type-enclosing \
    -position "$layer_provider_position" -index 0 -verbosity 0 \
    -filename main.ml < main.ml
)

generic_error_hover_compact=$(printf '%s' "$generic_error_hover" | tr -d '[:space:]')
error_after_offline_hover_compact=$(printf '%s' "$error_after_offline_hover" | tr -d '[:space:]')
layer_after_offline_hover_compact=$(printf '%s' "$layer_after_offline_hover" | tr -d '[:space:]')
generic_requirement_hover_compact=$(printf '%s' "$generic_requirement_hover" | tr -d '[:space:]')
requirement_after_metrics_hover_compact=$(printf '%s' "$requirement_after_metrics_hover" | tr -d '[:space:]')
layer_provider_hover_compact=$(printf '%s' "$layer_provider_hover" | tr -d '[:space:]')
require_text "$generic_error_hover_compact" '"class":"return"'
require_text "$error_after_offline_hover_compact" '"class":"return"'
require_text "$layer_after_offline_hover_compact" '"class":"return"'
require_text "$generic_requirement_hover_compact" '"class":"return"'
require_text "$requirement_after_metrics_hover_compact" '"class":"return"'
require_text "$layer_provider_hover_compact" '"class":"return"'
require_text "$generic_error_hover" "Offline"
require_text "$generic_error_hover" "Denied"
reject_text "$generic_error_hover" "Missing"
reject_text "$generic_error_hover" "Timeout"
require_text "$error_after_offline_hover" "Denied"
reject_text "$error_after_offline_hover" "Offline"
require_text "$layer_after_offline_hover" "Denied"
reject_text "$layer_after_offline_hover" "Missing"
reject_text "$layer_after_offline_hover" "Offline"
require_text "$generic_requirement_hover" "Metrics"
require_text "$generic_requirement_hover" "Audit"
reject_text "$generic_requirement_hover" "Logger"
reject_text "$generic_requirement_hover" "Clock"
require_text "$requirement_after_metrics_hover" "Audit"
reject_text "$requirement_after_metrics_hover" "Metrics"
require_text "$layer_provider_hover" "Clock"
reject_text "$layer_provider_hover" "Logger"

test -s "$trace" || fail "installed resolver was not executed by Merlin"
while IFS= read -r executed; do
  case "$executed" in
    "$prefix"/*) ;;
    *) fail "resolver executed outside the temporary prefix: $executed" ;;
  esac
done < "$trace"

printf '%s\n' "installed resolver: ok"
printf '%s\n' "raw Merlin generic error hover: narrow"
printf '%s\n' "raw Merlin residual error hover: narrow"
printf '%s\n' "raw Merlin Layer error hover: narrow"
printf '%s\n' "raw Merlin generic requirement hover: narrow"
printf '%s\n' "raw Merlin residual requirement hover: narrow"
printf '%s\n' "raw Merlin Layer provider hover: narrow"

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
