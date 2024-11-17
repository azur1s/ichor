open Utils
open Loc
open Lex
open Typed

type cst =
  | CUnit
  | CBool  of bool
  | CInt   of int
  | CFloat of float
  | CSym   of string
  | CBin   of cst spanned * bin * cst spanned
  | CApp   of cst spanned * cst spanned
  | CIf of
    { cond: cst spanned
    ; t: cst spanned
    ; f: cst spanned
    }
  | CBlock of cst spanned list
  | CLet of
    { name: string spanned
    ; body: cst spanned
    ; args: (string spanned * typ option) list
    ; ret: typ option
    ; in_: cst spanned
    }
  [@@deriving show]

type p =
  { input: token spanned list
  ; file: string
  ; mutable loc: int
  }

let make_span p start =
  { file = p.file
  ; start = start
  ; end_ = p.loc
  }

let ( let* ) x f =
  match x with
  | Ok v -> f v
  | Error e -> Error e

let ( @ ) list i = List.nth list i

let peek p =
  if p.loc < List.length p.input then
    Some (p.input @ p.loc)
  else
    None

let advance p =
  if p.loc < List.length p.input then (
    p.loc <- p.loc + 1;
    Some (p.input @ (p.loc - 1))
  ) else
    None

let advance_return p r =
  let _ = advance p
  in r

let expect_cond p f expect_str =
  match peek p with
  | Some (t, s) when f t -> advance_return p (Ok (t, s))
  | Some (t, s) -> Error ("Expected " ^ expect_str ^ ", found " ^ string_of_token t, s)
  | None -> Error ("Expected " ^ expect_str ^ ", found end of file", make_span p p.loc)

let expect p tk =
  expect_cond p ((=) tk) (string_of_token tk)

let maybe p tk =
  match expect_cond p ((=) tk) "" with
  | Ok t -> Some t
  | Error _ -> None

let parse_sym p =
  let* (sym, span) = expect_cond p (fun x -> match x with
    | TkSym _ -> true
    | _ -> false)
    "symbols"
  in match sym with
    | TkSym s -> Ok (s, span)
    | _ -> unreachable __LOC__

let many_delim p f delim =
  let rec many_acc p acc =
    match f p with
    | Ok v -> (
      match expect p delim with
      | Ok    _ -> many_acc p (v :: acc)
      | Error _ -> Ok (List.rev @@ v :: acc))
    | Error e -> Error e
  in
  many_acc p []

let many_cond p f =
  let rec many_cond_acc p acc =
    match peek p with
    | Some (t, s) when f t -> (
        let _ = advance p in
        many_cond_acc p ((t, s) :: acc))
    | _ -> Ok (List.rev acc)
  in
  many_cond_acc p []

let parse_typ p =
  match peek p with
  | Some (TkSym s, _) ->
    let _ = advance p in (match s with
    | "unit"  -> Ok TyUnit
    | "bool"  -> Ok TyBool
    | "int"   -> Ok TyInt
    | "float" -> Ok TyFloat
    | s -> Ok (TyCustom s))
  | Some (t, s) -> Error ("Expected type, found " ^ string_of_token t, s)
  | None -> Error ("Expected type, found end of file", make_span p p.loc)

let parse_args p =
  let rec parse_loop p acc =
    match peek p with
    | Some (TkSym s, span) ->
      let _ = advance p in
      parse_loop p @@ ((s, span), None) :: acc
    | Some (TkOpen Paren, _) ->
      let _ = advance p in
      let* sym = parse_sym p in
      let* _ = expect p TkColon in
      let* typ = parse_typ p in
      let* _ = expect p @@ TkClose Paren in
      parse_loop p @@ (sym, Some typ) :: acc
    | _ -> Ok (List.rev acc)
  in
  parse_loop p []

let rec parse_atom p =
  match peek p with
  | Some (t, span) -> (match t with
    | TkUnit -> advance_return p (Ok (CUnit, span))
    | TkBool  x -> advance_return p (Ok (CBool x, span))
    | TkInt   x -> advance_return p (Ok (CInt x, span))
    | TkFloat x -> advance_return p (Ok (CFloat x, span))
    | TkSym   x -> advance_return p (Ok (CSym x, span))
    | TkOpen Paren ->
      let _ = advance p in
      let* (exp, _) = parse_expr p 0 in
      let* (_, end_span) = expect p (TkClose Paren) in
      Ok (exp, span_union span end_span)
    | TkIf ->
      let _ = advance p in
      let* exp = parse_expr p 0 in
      let* _ = expect p TkThen in
      let* t = parse_expr p 0 in
      let* _ = expect p TkElse in
      let* f = parse_expr p 0 in
      Ok (CIf { cond = exp; t = t; f = f; }, span_union span (snd f))
    | TkLet ->
      let _ = advance p in
      let* sym = parse_sym p in
      let* args = parse_args p in
      let colon = maybe p TkColon in
      let* typ = if Option.is_some colon
        then Result.map Option.some (parse_typ p)
        else Ok None
      in
      let* _ = expect p TkAssign in
      let* body = parse_expr p 0 in
      let* _ = expect p TkIn in
      let* in_ = parse_expr p 0 in
      Ok (CLet
        { name = sym
        ; body = body
        ; args = args
        ; ret = typ
        ; in_ = in_
        }, span_union span (snd in_))
    | TkOpen Brace ->
      let _ = advance p in
      let* exprs = many_delim p (fun p -> parse_expr p 0) TkSemi in
      let* (_, end_span) = expect p (TkClose Brace) in
      Ok (CBlock exprs, span_union span end_span)
    | t -> Error ("Expected atom, found " ^ string_of_token t, span))
  | None -> Error ("Expected atom, found end of file", make_span p p.loc)

and binding_power = function
  | Mul | Div | Mod -> 50, 51
  | Add | Sub -> 40, 41
  | Lt | Lte | Gt | Gte -> 30, 31
  | Eq | Neq -> 20, 21
  | And | Or -> 10, 11

and parse_expr p min_bp =
  let rec parse_loop lhs =
    match peek p with
    (* Binary operator *)
    | Some (TkBin bin, _) ->
      let l_pw, r_pw = binding_power bin in
      if l_pw < min_bp then
        Ok lhs
      else
        let _ = advance p in
        let* rhs = parse_expr p r_pw in
        parse_loop (CBin (lhs, bin, rhs), span_union (snd lhs) (snd rhs))
    (* Application *)
    | Some _ ->
      (* Try parse, if goes wrong (e.g. found keywords) just return lhs *)
      (match parse_expr p min_bp with
      | Ok x -> parse_loop (CApp (lhs, x), span_union (snd lhs) (snd x))
      | Error _ -> Ok lhs)
    | None -> Ok lhs
  in

  let* lhs = parse_atom p in
  parse_loop lhs

let parse ?(file="<anonymous>") tks =
  let p = { input = tks; file = file; loc = 0 } in
  match parse_expr p 0 with
  | Ok v -> if List.length p.input = p.loc - 1
      then Ok v
      else let next = advance p in
        (match next with
        | Some (t, s) -> Error ("Unexpected " ^ string_of_token t ^ ", expected end of file", s)
        | None -> Ok v)
  | Error e -> Error e