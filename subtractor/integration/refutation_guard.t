The final compiler validates the wildcard refutation emitted after generated
forwarding cases. Incomplete forwarding cannot compile.

  $ cat > incomplete.ml <<'EOF'
  > type error = [ `A | `B ]
  > let handle : error -> unit = function
  >   | `A -> ()
  >   | _ -> .
  > EOF
  $ ocamlc -color never -w +11 -c incomplete.ml > incomplete.out 2>&1
  [2]
  $ grep -F "could not be refuted" incomplete.out
  Error: This match case could not be refuted.

Complete nonempty forwarding compiles without warning 11.

  $ cat > complete.ml <<'EOF'
  > type error = [ `A ]
  > let handle : error -> unit = function
  >   | `A -> ()
  >   | _ -> .
  > EOF
  $ ocamlc -color never -w +11 -c complete.ml 2> complete.err
  $ test ! -s complete.err

An exhausted marker keeps the following wildcard case so warning 11 remains
visible.

  $ cat > exhausted.ml <<'EOF'
  > type error = [ `A ]
  > let handle : error -> unit = function
  >   | `A -> ()
  >   | _ -> .
  >   | _ -> assert false
  > EOF
  $ ocamlc -color never -w +11 -c exhausted.ml 2> exhausted.err
  $ grep -F "Warning 11" exhausted.err
  Warning 11 [redundant-case]: this match case is unused.
