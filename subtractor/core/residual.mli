(** Pure subtraction and output proof calculation. Complete unguarded arms are
    removed from generated fallback. Guarded arms are validated but never
    subtract because their guards may fail. Explicit forwarding and recovery
    evidence are added back to the output set. *)
type guard = Unguarded | Guarded

type action = Handle | Forward

type target = Complete_leaf of Identity.t | Structural_member of Atom.t

type arm
type t

val arm : target:target -> guard:guard -> action:action -> arm
val target : arm -> target
val guard : arm -> guard
val action : arm -> action

val calculate :
  input:Proof.t ->
  arms:arm list ->
  recovery:Leaf.t list ->
  (t, Diagnostic.code) result

val kind : t -> Kind.t
val input : t -> Proof.t
val arms : t -> arm list
val handled : t -> Leaf.t list
val forwarded : t -> Leaf.t list
val recovery : t -> Leaf.t list
val residual : t -> Leaf.t list
val output : t -> Leaf.t list
val compare : t -> t -> int
val equal : t -> t -> bool
