let () =
  match Hamlet_subtractor_resolver_server.run () with
  | Ok () -> ()
  | Error message ->
      prerr_endline message;
      exit 2
