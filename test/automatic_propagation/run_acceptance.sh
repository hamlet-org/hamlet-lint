#!/bin/sh
set -eu

root=$(CDPATH= cd "$(dirname "$0")/../.." && pwd)
cd "$root"

dune_cmd() {
  dune "$@"
}

merlin_cmd() {
  ocamlmerlin "$@"
}

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

assert_final_ppx() {
  final_ppx_file=$1
  final_ppx_context=$2
  if grep -E '\[%%?ocaml\.error' "$final_ppx_file" >/dev/null; then
    fail "$final_ppx_context returned an embedded Merlin PPX error"
  fi
  if grep -E 'hamlet\.subtractor\.(marker|upstream|callee|handler|owner)\.v1' \
    "$final_ppx_file" >/dev/null; then
    fail "$final_ppx_context retained an internal elaboration marker"
  fi
  if grep -E '\|[[:space:]]+_[[:space:]]+->[[:space:]]+\(\(assert false\)' \
    "$final_ppx_file" >/dev/null; then
    fail "$final_ppx_context retained a probe assert false arm"
  fi
}

dump_ppxed_buffer() {
  source_file=$1
  buffer_file=$2
  output_file=$3
  response_file="$tmp_dir/$(basename "$buffer_file").merlin.json"
  merlin_cmd single dump -what ppxed-source -filename "$source_file" \
    <"$buffer_file" >"$response_file"
  dune_cmd exec test/automatic_propagation/automatic_propagation_merlin_source.exe \
    "$response_file" >"$output_file"
  assert_final_ppx "$output_file" "Merlin PPX output for $buffer_file"
}

dump_ppxed_source() {
  source_file=$1
  output_file=$2
  dump_ppxed_buffer "$source_file" "$source_file" "$output_file"
}

dump_typedtree() {
  filename=$1
  buffer=$2
  output_file=$3
  response_file="$tmp_dir/$(basename "$buffer").typedtree.json"
  merlin_cmd single dump -what typedtree -filename "$filename" \
    <"$buffer" >"$response_file"
  dune_cmd exec test/automatic_propagation/automatic_propagation_merlin_source.exe \
    "$response_file" >"$output_file"
}

assert_typed_subset_forwarder() {
  typedtree_file=$1
  expected_residual=$2
  context=$3
  binding_file="$tmp_dir/$context.binding.typedtree"
  awk '
    /Tpat_var "case_error_cross_subset\// { capture = 1 }
    capture && /^  structure_item / { exit }
    capture { print }
  ' "$typedtree_file" >"$binding_file"
  if ! grep -F 'Tpat_var "case_error_cross_subset/' "$binding_file" \
    >/dev/null; then
    fail "Merlin typedtree omitted case_error_cross_subset for $context"
  fi
  if grep -F 'attribute "hamlet.subtractor.marker.v1"' "$binding_file" \
    >/dev/null; then
    fail "Merlin typed the internal marker for $context"
  fi
  if grep -F 'Texp_assert' "$binding_file" >/dev/null; then
    fail "Merlin typed the probe assert false arm for $context"
  fi
  forwarded_type=$(
    awk '
      /Tpat_extra_type / { last_type = $0 }
      /Combinators\.fail"/ { print last_type; exit }
    ' "$binding_file"
  )
  case "$forwarded_type" in
    *"Storage.Errors.$expected_residual\""*) ;;
    *)
      fail "Merlin typedtree did not forward $expected_residual for $context"
      ;;
  esac
}

dump_hover() {
  filename=$1
  buffer=$2
  position=$3
  output_file=$4
  response_file="$tmp_dir/$(basename "$buffer").hover.json"
  merlin_cmd single type-enclosing -verbosity 0 -position "$position" \
    -filename "$filename" <"$buffer" >"$response_file"
  dune_cmd exec test/automatic_propagation/automatic_propagation_merlin_type.exe \
    "$response_file" >"$output_file"
}

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/hamlet-automatic-propagation.XXXXXX")
dependency_source=test/automatic_propagation/automatic_propagation_external.ml
positive_cmt=_build/default/test/automatic_propagation/.automatic_propagation_positive.objs/byte/automatic_propagation_positive.cmt
dependency_backup="$tmp_dir/automatic_propagation_external.ml.backup"
dependency_modified=0

cleanup() {
  if [ "$dependency_modified" -eq 1 ]; then
    cp "$dependency_backup" "$dependency_source"
  fi
  rm -rf "$tmp_dir"
}

trap cleanup EXIT HUP INT TERM

dune_cmd build @test/automatic_propagation/automatic-propagation-acceptance
dump_ppxed_source test/automatic_propagation/automatic_propagation_positive.ml \
  "$tmp_dir/automatic_propagation_positive.pp.ml"
dune_cmd exec test/automatic_propagation/automatic_propagation_expansion_dump.exe \
  "$tmp_dir/automatic_propagation_positive.pp.ml" >"$tmp_dir/automatic_propagation_expansion.actual"
if grep -E 'propagate_[es]\.auto' "$tmp_dir/automatic_propagation_expansion.actual" \
  >/dev/null; then
  printf '%s\n' 'saved buffer retained an auto marker' >&2
  exit 1
fi
diff -u test/automatic_propagation/automatic_propagation_expansion.expected \
  "$tmp_dir/automatic_propagation_expansion.actual"
dump_typedtree test/automatic_propagation/automatic_propagation_positive.ml \
  test/automatic_propagation/automatic_propagation_positive.ml "$tmp_dir/saved.typedtree"
assert_typed_subset_forwarder "$tmp_dir/saved.typedtree" storage_timeout saved

subset_line=$(grep -n '^let case_error_cross_subset =' \
  test/automatic_propagation/automatic_propagation_positive.ml | cut -d: -f1)
dump_hover test/automatic_propagation/automatic_propagation_positive.ml \
  test/automatic_propagation/automatic_propagation_positive.ml "$subset_line:5" \
  "$tmp_dir/saved.hover"
grep -Fx \
  '(string, Automatic_propagation_external.Storage.Errors.storage_timeout, never) t' \
  "$tmp_dir/saved.hover" >/dev/null

requirement_line=$(grep -n '^let case_requirement_cross_pipe =' \
  test/automatic_propagation/automatic_propagation_positive.ml | cut -d: -f1)
dump_hover test/automatic_propagation/automatic_propagation_positive.ml \
  test/automatic_propagation/automatic_propagation_positive.ml "$requirement_line:5" \
  "$tmp_dir/requirement.hover"
grep -Fx '(string, never, Automatic_propagation_external.Clock.Tag.r) t' \
  "$tmp_dir/requirement.hover" >/dev/null

saved_arm='#Automatic_propagation_external.Storage.Errors.storage_missing'
unsaved_arm='#Automatic_propagation_external.Storage.Errors.storage_timeout'
sed "s/$saved_arm/$unsaved_arm/g" test/automatic_propagation/automatic_propagation_positive.ml \
  >"$tmp_dir/automatic_propagation_positive.unsaved.ml"
dump_ppxed_buffer test/automatic_propagation/automatic_propagation_positive.ml \
  "$tmp_dir/automatic_propagation_positive.unsaved.ml" \
  "$tmp_dir/automatic_propagation_positive.unsaved.pp.ml"
dune_cmd exec test/automatic_propagation/automatic_propagation_expansion_dump.exe \
  "$tmp_dir/automatic_propagation_positive.unsaved.pp.ml" \
  >"$tmp_dir/automatic_propagation_expansion.unsaved"
if cmp -s "$tmp_dir/automatic_propagation_expansion.actual" \
  "$tmp_dir/automatic_propagation_expansion.unsaved"; then
  printf '%s\n' 'unsaved buffer did not change the final expansion' >&2
  exit 1
fi
if grep -F 'propagate_e.auto' "$tmp_dir/automatic_propagation_expansion.unsaved" \
  >/dev/null; then
  printf '%s\n' 'unsaved buffer retained an auto marker' >&2
  exit 1
fi
dump_typedtree test/automatic_propagation/automatic_propagation_positive.ml \
  "$tmp_dir/automatic_propagation_positive.unsaved.ml" "$tmp_dir/unsaved.typedtree"
assert_typed_subset_forwarder "$tmp_dir/unsaved.typedtree" storage_missing \
  unsaved
dump_hover test/automatic_propagation/automatic_propagation_positive.ml \
  "$tmp_dir/automatic_propagation_positive.unsaved.ml" "$subset_line:5" \
  "$tmp_dir/unsaved.hover"
grep -Fx \
  '(string, Automatic_propagation_external.Storage.Errors.storage_missing, never) t' \
  "$tmp_dir/unsaved.hover" >/dev/null

cp "$dependency_source" "$dependency_backup"
dependency_modified=1
sed -e 's/storage_corrupt/storage_checksum/g' \
  -e 's/Storage_corrupt/Storage_checksum/g' \
  "$dependency_source" >"$tmp_dir/automatic_propagation_external.ml.changed"
cp "$tmp_dir/automatic_propagation_external.ml.changed" "$dependency_source"
dune_cmd build \
  test/automatic_propagation/.automatic_propagation_positive.objs/byte/automatic_propagation_positive.cmt
dune_cmd exec test/automatic_propagation/automatic_propagation_cmt_dump.exe \
  "$positive_cmt" \
  >"$tmp_dir/automatic_propagation_types.dependency-changed"
grep -F 'Storage_checksum' \
  "$tmp_dir/automatic_propagation_types.dependency-changed" >/dev/null
if grep -F 'Storage_corrupt' \
  "$tmp_dir/automatic_propagation_types.dependency-changed" >/dev/null; then
  printf '%s\n' 'dependency edit retained a stale inferred type' >&2
  exit 1
fi
dump_ppxed_source test/automatic_propagation/automatic_propagation_positive.ml \
  "$tmp_dir/automatic_propagation_positive.dependency-changed.pp.ml"
dune_cmd exec test/automatic_propagation/automatic_propagation_expansion_dump.exe \
  "$tmp_dir/automatic_propagation_positive.dependency-changed.pp.ml" \
  >"$tmp_dir/automatic_propagation_expansion.dependency-changed"
cmp "$tmp_dir/automatic_propagation_expansion.actual" \
  "$tmp_dir/automatic_propagation_expansion.dependency-changed"
cp "$dependency_backup" "$dependency_source"
dependency_modified=0
dune_cmd build \
  test/automatic_propagation/.automatic_propagation_positive.objs/byte/automatic_propagation_positive.cmt
dune_cmd exec test/automatic_propagation/automatic_propagation_cmt_dump.exe \
  "$positive_cmt" \
  >"$tmp_dir/automatic_propagation_types.dependency-restored"
cmp test/automatic_propagation/automatic_propagation_types.expected \
  "$tmp_dir/automatic_propagation_types.dependency-restored"
dump_ppxed_source test/automatic_propagation/automatic_propagation_positive.ml \
  "$tmp_dir/automatic_propagation_positive.dependency-restored.pp.ml"
dune_cmd exec test/automatic_propagation/automatic_propagation_expansion_dump.exe \
  "$tmp_dir/automatic_propagation_positive.dependency-restored.pp.ml" \
  >"$tmp_dir/automatic_propagation_expansion.dependency-restored"
cmp "$tmp_dir/automatic_propagation_expansion.actual" \
  "$tmp_dir/automatic_propagation_expansion.dependency-restored"

while IFS='|' read -r fixture first second; do
  test -n "$fixture" || continue
  target="test/automatic_propagation/negative/$fixture.exe"
  if dune_cmd build --profile automatic-propagation-negative "$target" \
    >"$tmp_dir/$fixture.out" 2>&1; then
    printf '%s\n' "$fixture unexpectedly compiled" >&2
    exit 1
  fi
  if ! grep -F "$first" "$tmp_dir/$fixture.out" >/dev/null; then
    printf '%s\n' "$fixture omitted expected diagnostic: $first" >&2
    sed -n '1,120p' "$tmp_dir/$fixture.out" >&2
    exit 1
  fi
  if ! grep -F "$second" "$tmp_dir/$fixture.out" >/dev/null; then
    printf '%s\n' "$fixture omitted expected fallback: $second" >&2
    sed -n '1,120p' "$tmp_dir/$fixture.out" >&2
    exit 1
  fi
done <test/automatic_propagation/automatic_propagation_diagnostics.expected

dump_ppxed_source test/automatic_propagation/automatic_propagation_external.ml \
  "$tmp_dir/automatic_propagation_external.pp.ml"
field_count=$(
  sed -n '/module Linear =/,/let storage_program/p' \
    "$tmp_dir/automatic_propagation_external.pp.ml" \
    | grep -Ec '^[[:space:]]+e[0-9]+: e[0-9]+ ->'
)
propagate_count=$(
  sed -n '/module Linear =/,/let storage_program/p' \
    "$tmp_dir/automatic_propagation_external.pp.ml" \
    | grep -c 'let propagate'
)
dispatch_count=$(
  sed -n '/module Linear =/,/let storage_program/p' \
    "$tmp_dir/automatic_propagation_external.pp.ml" \
    | grep -c 'let dispatch'
)
subset_count=$(
  sed -n '/module Linear =/,/let storage_program/p' \
    "$tmp_dir/automatic_propagation_external.pp.ml" \
    | grep -Ec '__Hamlet_rest_|expose_t_|type t_[0-9a-f]' || true
)
test "$field_count" -eq 16
test "$propagate_count" -eq 1
test "$dispatch_count" -eq 1
test "$subset_count" -eq 0
