open Common
open Utils
open Infer

type kterm =
  | KLit    of lit
  | KList   of kterm list
  | KTuple  of kterm list
  | KBin    of kterm * bin * kterm
  | KRecord of (string * kterm) list
  | KAccess of kterm * string
  | KApp    of kterm * kterm list
  | KLambda of string list * kterm
  | KIf of
    { cond: kterm
    ; t: kterm
    ; f: kterm
    }
  | KDef of
    { name: string
    ; body: kterm
    ; in_: kterm
    }
  | KFun of
    { name: string
    ; args: string list
    ; recr: bool
    ; body: kterm
    ; in_: kterm
    }
  | KDestruct of
    { names: string list
    ; body: kterm
    ; in_: kterm
    }
  | KCase of
    { value: kterm
    ; pats: (pattern * kterm) list
    ; else_: kterm
    }
  [@@deriving show, sexp_of]

and ktop =
  | KTDef of string * kterm * int
  | KTFun of
    { name: string
    ; args: string list
    ; recr: bool
    ; body: kterm
    ; id: int
    }
  [@@deriving show]

and norm_context =
  { mutable id: int
  ; mutable env: (string * string) list
  }
  [@@deriving show]

let fresh_id ctx =
  let id = ctx.id in
  ctx.id <- ctx.id + 1;
  id

let define ctx name id =
  ctx.env <- (name, id) :: ctx.env

let rec uncurry t args =
  match t with
  | KApp (f, x) -> uncurry f (x @ args)
  | _ -> (t, args)

let flat_map f l = List.map f l |> List.flatten

let rec norm_term (ctx: norm_context ref) term =
  match (fst term) with
  | TLit (LSym s, _) -> (match List.assoc_opt s !ctx.env with
    | Some id -> KLit (LSym id)
    | None -> KLit (LSym s))
  | TLit (l, _) -> KLit l
  | TList l ->
    let l = List.map (norm_term ctx) l in
    (* TODO put complex expression outside of list, tuple & record *)
    (* Example:
    [1, 2, let a = 3 in a, let f x = x + 1 in f 3]
    =>
    let a = 3 in
    let b =
      let f x = x + 1 in f 3
    in
    [1, 2, a, b] *)
    KList l
  | TTuple l -> KTuple (List.map (norm_term ctx) l)
  | TRecord l -> KRecord (List.map (fun (k, v) -> (fst k, norm_term ctx v)) l)
  | TAccess (r, k) -> KAccess (norm_term ctx r, fst k)
  | TBin (a, op, b) ->
    let a = norm_term ctx a in
    let b = norm_term ctx b in
    KBin (a, op, b)
  | TThen (a, b) ->
    let a = norm_term ctx a in
    let b = norm_term ctx b in
    KDef { name = "_then" ^ (fresh_id !ctx |> string_of_int); body = a; in_ =  b }
  (* Uncurry applications *)
  | TApp (f, x) -> uncurry (norm_term ctx f) [norm_term ctx x]
    |> fun (f, x) -> KApp (f, x)
  | TLambda { args; body; _ } -> KLambda
    (List.map (fun x -> fst @@ fst x) args, norm_term ctx body)
  | TIf { cond; t; f; _ } -> KIf
    { cond = norm_term ctx cond
    ; t = norm_term ctx t
    ; f = norm_term ctx f }
  | TDef { name; body; in_; _ } -> KDef
    { name = fst name
    ; body = norm_term ctx body
    ; in_ = norm_term ctx in_ }
  | TFun { name; args; body; in_; _ } ->
    let body = norm_term ctx body in
    let in_ = norm_term ctx in_ in
    KDef
      { name = fst name
      ; body = KLambda (List.map (fun x -> fst @@ fst x) args, body)
      ; in_ }
  | TDestruct { names; body; in_; _ } -> KDestruct
    { names = List.map fst names
    ; body = norm_term ctx body
    ; in_ = norm_term ctx in_ }
  | e -> todo __LOC__ ~reason:(show_term e)

let rec flatten_let = function
  (*
  Example:
  let a =
    let b =
      let c = 1
      in c
    in b
  in a
  =>
  let c = 1
  in let b = c
  in let a = b
  in a
  *)
  | KDef { name; body = KDef { name = name2; body = body2; in_ = in2 }; in_ } ->
    let ubody2 = flatten_let body2 |> flatten_let in
    let uin2 = flatten_let in2 in
    flatten_let @@ KDef
      { name = name2
      ; body = ubody2
      ; in_ = KDef
        { name = name
        ; body = uin2
        ; in_ = flatten_let in_
        } }
  | KDef { name; body; in_ } ->
    KDef { name; body = flatten_let body; in_ = flatten_let in_ }
  | x -> x

let norm_top (ctx: norm_context ref) top =
  let norm t =
    norm_term ctx t
    |> flatten_let
  in
  match top with
  | TTDef { name; body; _ } ->
    let name_id = fresh_id !ctx
      |> string_of_int
      |> fun x -> fst name ^ "_" ^ x in
    define !ctx (fst name) name_id;

    norm body
    |> fun body -> KTDef (name_id, body, (snd name).start)
  | TTFun { name; args; recr; body; _ } ->
    let name_id = match fst name with
      | "main" -> "main"
      | name -> fresh_id !ctx
        |> string_of_int
        |> fun x -> name ^ "_" ^ x in
    define !ctx (fst name) name_id;

    KTFun
      { name = name_id
      ; body = norm body
      ; recr
      ; args = List.map (fun x -> fst @@ fst x) args
      ; id = (snd name).start }

let norm tops =
  let ctx = ref { id = 0; env = [] } in
  (* List.map (fun x -> norm_top @@ fst x) tops *)
  List.map (fun (x, _) -> norm_top ctx x) tops
