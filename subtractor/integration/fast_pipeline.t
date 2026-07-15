The fast standalone PPX pipeline refuses automatic markers before attempting a
probe. Dune users must select the classic pipeline with staged_pps.

  $ cat > fast_pipeline.ml <<'EOF'
  > let handle value =
  >   Combinators.catch value ~handler:(fun error ->
  >     match error with
  >     | #Storage.Errors.read_error -> Combinators.success ()
  >     | [%hamlet.propagate_e.auto] -> .)
  > EOF
  $ ./hamlet_subtractor_fast_driver.exe --impl fast_pipeline.ml 2>&1 | grep -E "staged_pps|hamlet.te"
  Error: automatic propagation requires Dune's classic PPX pipeline; configure (staged_pps hamlet-subtractor.ppx), not (pps hamlet-subtractor.ppx); use an explicit [%hamlet.te ...] input universe with [%hamlet.propagate_e]
