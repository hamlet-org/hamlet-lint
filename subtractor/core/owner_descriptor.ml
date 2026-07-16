type module_name = Combinators | Layer

type channel = Error | Requirement

type forwarding = Effect_fail | Dispatch_need | Layer_fail_like

type contributor = No_contributor | Labelled_source

type t = {
  module_name : module_name;
  value_name : string;
  channel : channel;
  handler_label : string;
  handler_peel : int;
  required_label : string option;
  contributor : contributor;
  forwarding : forwarding;
  bind_upstream_once : bool;
}

let owner
    module_name
    value_name
    channel
    ?(handler_peel = 0)
    ?required_label
    ?(contributor = No_contributor)
    ?(bind_upstream_once = false)
    forwarding =
  {
    module_name;
    value_name;
    channel;
    handler_label = "handler";
    handler_peel;
    required_label;
    contributor;
    forwarding;
    bind_upstream_once;
  }

let owners =
  [
    owner Combinators "catch" Error Effect_fail;
    owner Combinators "provide" Requirement Dispatch_need;
    owner Layer "catch" Error ~bind_upstream_once:true Layer_fail_like;
    owner Layer "provide_to_effect" Requirement ~handler_peel:1
      ~required_label:"source" ~contributor:Labelled_source Dispatch_need;
    owner Layer "provide_to_layer" Requirement ~handler_peel:1
      ~required_label:"source" ~contributor:Labelled_source Dispatch_need;
    owner Layer "provide_merge_to_layer" Requirement ~handler_peel:1
      ~required_label:"source" ~contributor:Labelled_source Dispatch_need;
  ]

let find ~module_name ~value_name =
  List.find_opt
    (fun descriptor ->
      descriptor.module_name = module_name
      && String.equal descriptor.value_name value_name)
    owners

let module_path = function Combinators -> "Combinators" | Layer -> "Layer"

let display_name descriptor =
  "Hamlet." ^ module_path descriptor.module_name ^ "." ^ descriptor.value_name

let traced_layer_values =
  [
    "make";
    "provide_to_effect";
    "provide_to_layer";
    "merge_all";
    "merge_all_with_key";
    "provide_merge_to_layer";
    "fresh";
    "or_die";
    "catch";
    "catch_defect";
    "catch_cause";
    "tap";
    "tap_fail";
    "tap_defect";
    "tap_cause";
    "unwrap";
  ]
