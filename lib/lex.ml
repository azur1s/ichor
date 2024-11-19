open Common
open Utils
open Loc

type token =
  (* Literals *)
  | TkUnit
  | TkBool  of bool
  | TkInt   of int
  | TkFloat of float
  | TkSym   of string
  (* Operators *)
  | TkBin   of bin
  (* Delimiters *)
  | TkAssign
  | TkSemi
  | TkColon
  | TkBar
  | TkBarElse
  | TkArrow
  | TkOpen  of delim
  | TkClose of delim
  (* Keywords *)
  | TkIf  | TkThen | TkElse
  | TkLet | TkIn
  | TkCase | TkOf
  [@@deriving show]

and delim =
  | Paren
  | Brack
  | Brace
  [@@deriving show]

let string_of_token = function
  | TkUnit -> "()"
  | TkBool  x -> string_of_bool x
  | TkInt   x -> string_of_int x
  | TkFloat x -> string_of_float x
  | TkSym   x -> x
  (* Operators *)
  | TkBin   x -> (match x with
    | Add -> "+"
    | Sub -> "-"
    | Mul -> "*"
    | Div -> "/"
    | Mod -> "%"
    | Eq  -> "=="
    | Neq -> "!="
    | Lt  -> "<"
    | Lte -> "<="
    | Gt  -> ">"
    | Gte -> ">="
    | And -> "&&"
    | Or  -> "||")
  (* Delimiters *)
  | TkAssign -> "="
  | TkSemi -> ";"
  | TkColon -> ":"
  | TkBar -> "|"
  | TkBarElse -> "\\"
  | TkArrow -> "->"
  | TkOpen  x -> (match x with
    | Paren -> "("
    | Brack -> "["
    | Brace -> "{")
  | TkClose x -> (match x with
    | Paren -> ")"
    | Brack -> "]"
    | Brace -> "}")
  (* Keywords *)
  | TkIf   -> "if"
  | TkThen -> "then"
  | TkElse -> "else"
  | TkLet  -> "let"
  | TkIn   -> "in"
  | TkCase -> "case"
  | TkOf   -> "of"

type l =
  { input: string
  (* Location *)
  ; file: string
  ; mutable loc: int
  }

let make_span l start =
  { file = l.file
  ; start = start
  ; end_ = l.loc
  }

let peek l =
  if l.loc < String.length l.input then
    Some l.input.[l.loc]
  else
    None

let advance l =
  if l.loc < String.length l.input then (
    l.loc <- l.loc + 1;
    Some l.input.[l.loc - 1]
  ) else
    None

let explode s = List.init (String.length s) (String.get s)

let is_ws = function
  | ' ' | '\t' | '\n' | '\r' -> true
  | _ -> false

let is_digit = function
  | '0' .. '9' -> true
  | _ -> false

let delim_of_string = function
  | "=" -> TkAssign
  | ";" -> TkSemi
  | ":" -> TkColon
  | "|" -> TkBar
  | "\\" -> TkBarElse
  | _ -> unreachable __LOC__

let char_one_of str c = List.exists ((=) c) (explode str)
let is_bin_char c = char_one_of "+-*/%=!><&!" c

let multi_char_bin = [
  "=="; "!="; "<="; ">="; "&&"; "||"
]

let bin_of_string = function
  | "+"  -> Add
  | "-"  -> Sub
  | "*"  -> Mul
  | "/"  -> Div
  | "%"  -> Mod
  | "==" -> Eq
  | "!=" -> Neq
  | "<"  -> Lt
  | "<=" -> Lte
  | ">"  -> Gt
  | ">=" -> Gte
  | "&&" -> And
  | "||" -> Or
  | b -> unreachable @@ __LOC__ ^ " " ^ b

let is_atom_char = function
  | 'a'..'z' | 'A'..'Z' | '_' -> true
  | _ -> false

let to_delim s =
  let t = function
    | '(' | ')' -> Paren
    | '[' | ']' -> Brack
    | '{' | '}' -> Brace
    | _ -> unreachable __LOC__
  in match s with
    | '(' | '[' | '{' -> TkOpen (t s)
    | ')' | ']' | '}' -> TkClose (t s)
    | _ -> unreachable __LOC__

let rec tokenize_acc l acc =
  let when_peek_is f =
    match peek { l with loc = l.loc + 1 } with
    | Some c -> f c
    | None -> false
  in

  let when_peek_is_or_end f =
    match peek { l with loc = l.loc + 1 } with
    | Some c -> f c
    | None -> true
  in

  match peek l with
  | None ->
    Ok (List.rev acc)
  | Some c ->
    let start = l.loc in
    match c with
    (* Whitespace *)
    | c when is_ws c ->
      let _ = advance l in
      tokenize_acc l acc
    | c when c = '-' && when_peek_is ((=) '-') ->
      let _ = advance l in
      let rec skip_line () =
        match peek l with
        | Some '\n' ->
          let _ = advance l in
          ()
        | Some _ ->
          let _ = advance l in
          skip_line ()
        | None -> ()
      in
      skip_line ();
      tokenize_acc l acc
    (* Delimiters *)
    | c when c = '(' && when_peek_is ((=) ')') ->
      let _ = advance l in
      let _ = advance l in
      let span = make_span l start in
      tokenize_acc l @@ (TkUnit, span) :: acc
    | c when c = '-' && when_peek_is ((=) '>') ->
      let _ = advance l in
      let _ = advance l in
      let span = make_span l start in
      tokenize_acc l @@ (TkArrow, span) :: acc
    | c when char_one_of "=;:|\\" c && when_peek_is_or_end (fun x -> is_ws x) ->
      let _ = advance l in
      let span = make_span l start in
      tokenize_acc l @@ (delim_of_string (String.make 1 c), span) :: acc
    | '(' | ')' | '[' | ']' | '{' | '}' ->
      let _ = advance l in
      let span = make_span l start in
      tokenize_acc l @@ (to_delim c, span) :: acc
    (* Numbers *)
    | c when is_digit c || c = '.'
    || (c = '-' && when_peek_is (fun x -> is_digit x || x = '.')) ->
      (* Whole number part *)
      let rec read_whole acc =
        match peek l with
        | Some c when is_digit c ->
          let _ = advance l in
          let acc, is_float = read_whole (acc *. 10.0 +. float_of_int (Char.code c - Char.code '0')) in
          (acc, is_float)
        | Some '.' ->
          let _ = advance l in
          (read_dec acc 0.1, true)
        | _ -> (acc, false)
      (* Decimal part after `.` *)
      and read_dec acc factor =
        match peek l with
        | Some c when is_digit c ->
          let _ = advance l in
          let digit = float_of_int (Char.code c - Char.code '0') in
          read_dec (acc +. (digit *. factor)) (factor /. 10.0)
        | _ -> acc
      in
      let is_neg = c = '-' in
      let _ = if is_neg then ignore (advance l) in
      let (num, is_float) = read_whole 0.0 in
      let num = if is_neg then -.num else num in
      let span = make_span l start in
      let v = if is_float then TkFloat num else TkInt (int_of_float num) in
      tokenize_acc l @@ (v, span) :: acc
    (* Operators *)
    | c when is_bin_char c ->
      let fc = c in
      let _ = advance l in
      let op = match peek l with
        | Some c1 when is_bin_char c1 ->
          let potential_op = String.make 1 fc ^ String.make 1 c1 in
          if List.mem potential_op multi_char_bin then (
            let _ = advance l in
            potential_op
          ) else String.make 1 fc
        | _ -> String.make 1 fc
      in
      let span = make_span l start in
      tokenize_acc l @@ (TkBin (bin_of_string op), span) :: acc
    (* Symbol *)
    | c when is_atom_char c ->
      let rec read_atom acc =
        match peek l with
        | Some c when is_atom_char c || is_digit c ->
          let _ = advance l in
          read_atom (acc ^ String.make 1 c)
        | _ ->
          match acc with
          | "true"  -> TkBool true
          | "false" -> TkBool false
          | "if"    -> TkIf
          | "then"  -> TkThen
          | "else"  -> TkElse
          | "let"   -> TkLet
          | "in"    -> TkIn
          | "case"  -> TkCase
          | "of"    -> TkOf
          | _ -> TkSym acc
      in
      let _ = advance l in
      let atom = read_atom (String.make 1 c) in
      let span = make_span l start in
      tokenize_acc l @@ (atom, span) :: acc
    | _ ->
      let span = make_span l start in
      Error ("Unexpected character: " ^ String.make 1 c, span)

let tokenize l : (token spanned list, string spanned) result =
  tokenize_acc l []

let lex ?(file="<anonymous>") s =
  tokenize
    { input = s
    ; file = file
    ; loc = 0
    }