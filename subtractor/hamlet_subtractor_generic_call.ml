open Ppxlib
module A = Ast_builder.Default

let extension_name = "hamlet.forward.auto"
let call_attribute = "hamlet.subtractor.generic_call.v1"
let callee_attribute = "hamlet.subtractor.generic_callee.v1"
let source_attribute = "hamlet.subtractor.generic_source.v1"
let placeholder_attribute = "hamlet.subtractor.generic_placeholder.v1"

type call = {
  id : string;
  loc : Location.t;
  callee_loc : Location.t;
  source_loc : Location.t;
  placeholder_loc : Location.t;
}

type refusal_reason =
  | Not_a_final_argument
  | Labelled_argument
  | Missing_effect_argument
  | Multiple_placeholders

type refusal = { loc : Location.t; reason : refusal_reason }

type prepared = {
  base_structure : structure;
  probe_structure : structure;
  calls : call list;
  refusals : refusal list;
}

let string_payload value =
  PStr
    [ A.pstr_eval ~loc:Location.none (A.estring ~loc:Location.none value) [] ]

let attribute ~name ~value =
  {
    attr_name = { txt = name; loc = Location.none };
    attr_payload = string_payload value;
    attr_loc = Location.none;
  }

let add_attribute ~name ~value expression =
  {
    expression with
    pexp_attributes = attribute ~name ~value :: expression.pexp_attributes;
  }

let extension = function
  | { pexp_desc = Pexp_extension ({ txt; _ }, PStr []); _ }
    when String.equal txt extension_name ->
      true
  | _ -> false

let has_extension expression =
  let found = ref false in
  let iterator =
    object
      inherit Ast_traverse.iter as super

      method! expression expression =
        if extension expression then found := true
        else super#expression expression
    end
  in
  iterator#expression expression;
  !found

let location_key loc =
  (loc.loc_start.pos_fname, loc.loc_start.pos_cnum, loc.loc_end.pos_cnum)

let claim_extensions claimed expression =
  let iterator =
    object
      inherit Ast_traverse.iter as super

      method! expression expression =
        if extension expression then
          Hashtbl.replace claimed (location_key expression.pexp_loc) ();
        super#expression expression
    end
  in
  iterator#expression expression

let call_id ~structure_digest ~loc ~ordinal =
  let digest =
    String.concat "\000"
      [
        structure_digest;
        loc.loc_start.pos_fname;
        string_of_int loc.loc_start.pos_cnum;
        string_of_int loc.loc_end.pos_cnum;
        string_of_int ordinal;
      ]
    |> Digest.string
    |> Digest.to_hex
  in
  Printf.sprintf "generic-call:%s:%d" digest ordinal

let prepare structure =
  let structure_digest =
    Marshal.to_string structure [ Marshal.No_sharing ]
    |> Digest.string
    |> Digest.to_hex
  in
  let ordinal = ref 0 in
  let calls = ref [] in
  let refusals = ref [] in
  let claimed = Hashtbl.create 16 in
  let mapper =
    object (self)
      inherit Ast_traverse.map as super

      method private reject expression reason =
        claim_extensions claimed expression;
        refusals := { loc = expression.pexp_loc; reason } :: !refusals;
        expression

      method! expression expression =
        match expression.pexp_desc with
        | Pexp_apply (callee, arguments) -> (
            let placeholder_count =
              List.fold_left
                (fun count (_, argument) ->
                  if has_extension argument then count + 1 else count)
                0 arguments
            in
            if placeholder_count = 0 then super#expression expression
            else if placeholder_count > 1 then
              self#reject expression Multiple_placeholders
            else
              match List.rev arguments with
              | (label, placeholder) :: reversed_arguments
                when extension placeholder -> (
                  let arguments = List.rev reversed_arguments in
                  if label <> Nolabel then
                    self#reject placeholder Labelled_argument
                  else
                    match List.rev arguments with
                    | (Nolabel, source) :: _ ->
                        let id =
                          call_id ~structure_digest ~loc:expression.pexp_loc
                            ~ordinal:!ordinal
                        in
                        incr ordinal;
                        Hashtbl.replace claimed
                          (location_key placeholder.pexp_loc)
                          ();
                        let placeholder =
                          A.pexp_assert ~loc:placeholder.pexp_loc
                            (A.ebool ~loc:placeholder.pexp_loc false)
                          |> add_attribute ~name:placeholder_attribute ~value:id
                        in
                        let callee =
                          super#expression callee
                          |> add_attribute ~name:callee_attribute ~value:id
                        in
                        let arguments =
                          List.map
                            (fun (argument_label, argument) ->
                              let argument = super#expression argument in
                              if
                                argument_label = Nolabel
                                && Location.compare argument.pexp_loc
                                     source.pexp_loc
                                   = 0
                              then
                                ( argument_label,
                                  add_attribute ~name:source_attribute ~value:id
                                    argument )
                              else (argument_label, argument))
                            arguments
                        in
                        calls :=
                          {
                            id;
                            loc = expression.pexp_loc;
                            callee_loc = callee.pexp_loc;
                            source_loc = source.pexp_loc;
                            placeholder_loc = placeholder.pexp_loc;
                          }
                          :: !calls;
                        {
                          expression with
                          pexp_desc =
                            Pexp_apply
                              (callee, arguments @ [ (Nolabel, placeholder) ]);
                        }
                        |> add_attribute ~name:call_attribute ~value:id
                    | _ -> self#reject expression Missing_effect_argument)
              | _ -> self#reject expression Not_a_final_argument)
        | _ -> super#expression expression
    end
  in
  let probe_structure = mapper#structure structure in
  let iterator =
    object
      inherit Ast_traverse.iter as super

      method! expression expression =
        (if extension expression then
           let key = location_key expression.pexp_loc in
           if not (Hashtbl.mem claimed key) then
             refusals :=
               { loc = expression.pexp_loc; reason = Not_a_final_argument }
               :: !refusals);
        super#expression expression
    end
  in
  iterator#structure structure;
  {
    base_structure = structure;
    probe_structure;
    calls = List.rev !calls;
    refusals = List.rev !refusals;
  }
