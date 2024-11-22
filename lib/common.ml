(* Common types used by representations *)
type lit =
  | LUnit
  | LBool  of bool
  | LInt   of int
  | LFloat of float
  | LStr   of string
  | LSym   of string
  [@@deriving show]

and pattern =
  | PatLit of lit
  [@@deriving show]

and bin =
  | Add | Sub | Mul | Div | Mod
  | Eq  | Neq | Lt  | Lte | Gt | Gte
  | And | Or
  [@@deriving show]

and typ =
  | TyConst of string
  | TyTuple of typ * typ
  | TyArrow of typ * typ
  | TyConstructor of string * typ
  | TyVar of string (* Generated by inference *)
  [@@deriving show]

let string_of_lit = function
  | LUnit -> "ok" (* Assuming this is Erlang's unit expression *)
  | LBool b -> string_of_bool b
  | LInt i -> string_of_int i
  | LFloat f -> string_of_float f
  | LStr s -> "\"" ^ s ^ "\""
  | LSym s -> s

let string_of_bin = function
  | Add -> "+"
  | Sub -> "-"
  | Mul -> "*"
  | Div -> "/"
  | Mod -> "rem"
  | Eq -> "=="
  | Neq -> "/="
  | Lt -> "<"
  | Lte -> "<="
  | Gt -> ">"
  | Gte -> ">="
  (* Short-circuiting *)
  | And -> "andalso"
  | Or -> "orelse"

let rec string_of_typ = function
  | TyConst s -> s
  | TyTuple (a, b) -> string_of_typ a ^ " * " ^ string_of_typ b
  | TyArrow (a, b) -> string_of_typ a ^ " -> " ^ string_of_typ b
  | TyConstructor (f, b) -> string_of_typ b ^ " " ^ f
  | TyVar s -> s
