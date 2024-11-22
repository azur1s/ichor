open Common
open Utils
open Norm

type erl_expr =
  | ELit of lit
  | EList of erl_expr list
  | EBin of erl_expr * bin * erl_expr
  | EApp of erl_expr * erl_expr list
  (* fun (args) -> e end *)
  | ELam of string list * erl_expr
  (* e1, e2. *)
  | EThen of erl_expr * erl_expr
  (* x = e *)
  | ELet of string * erl_expr
  | EIf of erl_expr * erl_expr * erl_expr
  [@@deriving show]


and erl_top =
  (* -export([f/i]) *)
  | EExport of (string * int) list
  | EDef of string * erl_expr
  (* fun(args) -> e. *)
  | EFun of
    { name: string
    ; args: string list
    ; expr: erl_expr
    }
  [@@deriving show]

let rec string_of_erl_expr ?(cap=true) = function
  | ELit (LSym s) when cap -> capitalize_first s
  | ELit l -> string_of_lit l
  | EList l -> Printf.sprintf "[%s]" (String.concat ", " (List.map string_of_erl_expr l))
  | EBin (a, op, b) ->
    Printf.sprintf "%s %s %s"
      (string_of_erl_expr a)
      (string_of_bin op)
      (string_of_erl_expr b)
  | EApp (f, args) ->
    Printf.sprintf "%s(%s)"
      (string_of_erl_expr f ~cap:false)
      (String.concat ", " (List.map string_of_erl_expr args))
  | ELam (args, e) ->
    Printf.sprintf "fun(%s) -> %s end"
      (String.concat ", " args)
      (string_of_erl_expr e)
  | EThen (e1, e2) ->
    Printf.sprintf "%s,\n  %s" (string_of_erl_expr e1) (string_of_erl_expr e2)
  | ELet (x, e) -> Printf.sprintf "%s = %s" (capitalize_first x) (string_of_erl_expr e)
  | EIf (e, t, f) ->
    Printf.sprintf "if\n    %s -> %s;\n    true -> %s\n  end"
      (string_of_erl_expr e)
      (string_of_erl_expr t)
      (string_of_erl_expr f)

let string_of_erl_top = function
  | EExport exports ->
    Printf.sprintf "-export([%s])."
      (String.concat ", " (List.map (fun (f, a) -> Printf.sprintf "%s/%d" f a) exports))
  | EDef (x, e) -> Printf.sprintf "%s() ->\n  %s." x (string_of_erl_expr e)
  | EFun { name; args; expr } ->
    Printf.sprintf "%s(%s) ->\n  %s."
      name
      (String.concat ", " (List.map capitalize_first args))
      (string_of_erl_expr expr)

type ctx =
  { mutable vars: (string * erl_expr) list
  ; mutable funs: (string * string list * erl_expr * string list) list
  ; mutable bounds: string list
  }

let rec comp_term ctx term =
  match term with
  | KLit (LSym s) ->
    ctx.bounds <- s :: ctx.bounds;
    ELit (LSym s)
  | KLit l -> ELit l
  | KBin (a, op, b) -> EBin (comp_term ctx a, op, comp_term ctx b)
  | KList l -> EList (List.map (comp_term ctx) l)
  | KThen (a, b) -> EThen (comp_term ctx a, comp_term ctx b)
  | KApp (KLit (LSym "__external__"), xs) ->
    (match xs with
    | KLit (LStr f) :: args -> EApp (ELit (LSym f), List.map (comp_term ctx) args)
    | x -> List.map show_kterm x
      |> String.concat ", "
      |> (^) __LOC__
      |> (^) "Invalid external call: "
      |> failwith)
  | KApp (KLit (LSym s), xs) ->
    let rec lookup_bounds = function
      | [] -> failwith "Function not found"
      | (name, _, _, bounds) :: _ when name = s -> bounds
      | _ :: rest -> lookup_bounds rest in
    let bounds = lookup_bounds ctx.funs in
    let args = List.map (comp_term ctx) xs
      |> (@) (List.map (fun x -> ELit (LSym x)) bounds)
    in
    EApp (ELit (LSym s), args)
  | KApp (f, xs) ->
    EApp (comp_term ctx f, List.map (comp_term ctx) xs)
  | KIf { cond; t; f } ->
    EThen (
      ELet ("__if__", comp_term ctx cond),
      EIf (
        EBin (ELit (LSym "__if__"), Eq, ELit (LBool true)),
        comp_term ctx t,
        comp_term ctx f))
  | KDef { name; body; in_ ; _ } ->
    ctx.vars <- (name, comp_term ctx body) :: ctx.vars;
    comp_term ctx in_
  | KFun { name; args; body; in_; _ } ->
    ctx.bounds <- [];
    let body = comp_term ctx body in
    (* Filter out what variables is not bounded by `let`, since Erlang does *)
    (* not allow defining functions inside functions *)
    let vs = List.filter (fun v -> not @@ List.mem v args) ctx.bounds in
    let args = args @ vs in
    ctx.funs <- (name, args, body, vs) :: ctx.funs;
    comp_term ctx in_
  | e -> todo __LOC__ ~reason:(show_kterm e)

let comp_top ctx top =
  match top with
  | KTDef (name, body) -> EDef (name, comp_term ctx body)
  | KTFun { name; args; body; _ } ->
    EFun { name; args; expr = comp_term ctx body }

let comp terms =
  let ctx = { vars = []; funs = []; bounds = [] } in
  let comped = List.map (comp_top ctx) terms in

  let vars = List.map (fun (x, e) -> ELet (x, e)) ctx.vars |> List.rev in
  let funs = List.map (fun (name, args, body, _) -> EFun { name; args; expr = body }) ctx.funs in
  let exports = List.fold_left (fun acc -> function
      | EFun { name; args; _ } -> (name, List.length args) :: acc
      | _ -> acc
    ) [] comped in

  (* Look for main function, then insert vars in front of the expression *)
  let is_main = (function EFun { name = "main"; _ } -> true | _ -> false) in
  let comped = match List.find_opt is_main comped with
    | Some (EFun { name = "main"; args; expr }) ->
      let no_main = List.filter (fun x -> not (is_main x)) comped in
      let main_expr = List.fold_right (fun x acc -> EThen (x, acc)) vars expr in
      EFun { name = "main"; args; expr = main_expr } :: no_main
    | _ -> failwith "main function not found" in
  EExport exports :: funs @ comped
