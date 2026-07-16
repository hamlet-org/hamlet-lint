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

val owners : t list

val find : module_name:module_name -> value_name:string -> t option

val module_path : module_name -> string

val display_name : t -> string

val traced_layer_values : string list
