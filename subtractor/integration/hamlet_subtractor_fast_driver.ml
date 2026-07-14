let () =
  Hamlet_subtractor_ppx.activate_probe_phase |> ignore;
  Ppxlib.Driver.standalone ()
