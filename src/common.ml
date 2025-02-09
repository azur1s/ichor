(* Common types used by representations *)
open Loc
open Sexplib0
open Utils

type err =
  { msg : string
  ; hint : string option
  ; loc : span
  }
  [@@deriving show]

let err ?(hint="") msg loc =
  { msg; hint = if hint = "" then None else Some hint; loc }

let with_hint hint err =
  { err with hint = Some hint }

let err_ret ?(hint="") msg loc =
  let e = if hint = "" then
    err msg loc
  else
    err msg loc |> with_hint hint
  in Error e

let from_result = function
| Ok x -> x
| Error (msg, loc) -> err msg loc

let sexp_of_bool   b = Sexp.Atom (string_of_bool b)
let sexp_of_int    i = Sexp.Atom (string_of_int i)
let sexp_of_float  f = Sexp.Atom (string_of_float f)
let sexp_of_string s = Sexp.Atom s
let sexp_of_list f l = Sexp.List (List.map f l)
let sexp_of_option f = function
  | None -> Sexp.Atom "None"
  | Some x -> Sexp.List [Sexp.Atom "Some"; f x]

type lit =
  | LUnit
  | LBool  of bool
  | LInt   of int
  | LFloat of float
  | LStr   of string
  | LSym   of string
  [@@deriving show, sexp_of]

and pattern =
  | PatLit of lit
  [@@deriving show, sexp_of]

and bin =
  | Add | Sub | Mul | Div | Mod
  | Eq  | Neq | Lt  | Lte | Gt | Gte
  | And | Or
  | Cons
  [@@deriving show, sexp_of]

and typ =
  | TyConst of string
  | TyTuple of typ * typ
  | TyArrow of typ * typ
  | TyConstructor of string * typ
  | TyRecord of (string * typ) list
  | TyEnum of (string * typ option) list
  | TyInfer of string
  [@@deriving show, sexp_of]

let intrinsic_types = ["int"; "float"; "string"; "bool"; "unit"]

let string_of_lit = function
  | LUnit -> "null"
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
  | Cons -> "|"

let rec string_of_typ = function
  | TyConst s -> s
  | TyTuple (a, b) -> string_of_typ a ^ " * " ^ string_of_typ b
  | TyArrow (a, b) -> string_of_typ a ^ " -> " ^ string_of_typ b
  | TyRecord l -> "{" ^ String.concat ", " (List.map (fun (f, t) -> f ^ " : " ^ string_of_typ t) l) ^ "}"
  | TyConstructor (f, b) -> string_of_typ b ^ " " ^ f
  | TyEnum l ->
    let f (f, t) = match t with
      | None -> f
      | Some t -> f ^ " of " ^ string_of_typ t
    in
    String.concat " | " (List.map f l)
  | TyInfer s -> "'" ^ s

(* ['e, 'g1 -> 'e * 'f16] => ['a, 'b -> 'a * 'c] *)
let floor_types tys =
  let mappings = Hashtbl.create 10 in
  let rec floor_typ = function
    | TyConst _ as t -> t
    | TyTuple (a, b) -> TyTuple (floor_typ a, floor_typ b)
    | TyArrow (a, b) -> TyArrow (floor_typ a, floor_typ b)
    | TyRecord l -> TyRecord (List.map (fun (f, t) -> (f, floor_typ t)) l)
    | TyConstructor (f, b) -> TyConstructor (f, floor_typ b)
    | TyEnum l -> TyEnum (List.map (fun (f, t) -> (f, Option.map floor_typ t)) l)
    | TyInfer s ->
      if Hashtbl.mem mappings s then
        TyInfer (Hashtbl.find mappings s)
      else
        let i = Hashtbl.length mappings in
        Hashtbl.add mappings s (string_type_from_int i);
        TyInfer (string_type_from_int i)
  in
  List.map floor_typ tys