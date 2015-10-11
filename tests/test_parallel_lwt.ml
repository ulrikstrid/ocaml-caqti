(* Copyright (C) 2015  Petter A. Urkedal <paurkedal@gmail.com>
 *
 * This library is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or (at your
 * option) any later version, with the OCaml static compilation exception.
 *
 * This library is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public
 * License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this library.  If not, see <http://www.gnu.org/licenses/>.
 *)

open Caqti_query
open Lwt.Infix

let create_q = prepare_sql_p "CREATE TABLE test_parallel \
				(x int NOT NULL, y int NOT NULL)"
let drop_q = prepare_sql_p "DROP TABLE IF EXISTS test_parallel"
let insert_q = prepare_sql_p "INSERT INTO test_parallel VALUES (?, ?)"
let delete_q = prepare_sql_p "DELETE FROM test_parallel WHERE x = ?"
let select_1_q = prepare_sql_p "SELECT y FROM test_parallel WHERE x < ?"
let select_2_q = prepare_sql_p
  "SELECT sum(a.y*b.y) FROM test_parallel a JOIN test_parallel b ON a.x < b.x \
    WHERE b.x < ?"

let random_int () = Random.int (1 + Random.int 16)

let do_query =
  Caqti_lwt.Pool.use @@ fun (module C : Caqti_lwt.CONNECTION) ->
  match Random.int 4 with
  | 0 -> C.exec insert_q C.Param.[|int (random_int ()); int (random_int ())|] >>
	 Lwt.return 0
  | 1 -> C.exec delete_q C.Param.[|int (random_int ())|] >>
	 Lwt.return 0
  | 2 -> C.fold select_1_q C.Tuple.(fun t -> (+) (int 0 t))
			   C.Param.[|int (random_int ())|] 0
  | 3 -> C.find select_2_q C.Tuple.(option int 0)
			   C.Param.[|int (random_int ())|] >|=
	 (function None -> 0 | Some i -> i)
  | _ -> assert false

let rec list_diff f = function
  | x0 :: x1 :: xs -> f x1 x0 :: list_diff f (x1 :: xs)
  | [_] -> []
  | [] -> invalid_arg "list_diff"

let merge f xs acc =
  let rec loop = function
    | [] -> Lwt.return
    | x :: xs -> fun acc -> x >>= fun y -> loop xs (f y acc) in
  loop xs acc

let rec test2 pool n =
  if n = 0 then Lwt.return 0 else
  if n = 1 then do_query pool else
  let ns = Array.init (Random.int n * (Random.int n + 1) / n + 1)
		      (fun i -> Random.int n)
	|> Array.to_list |> (fun xs -> n :: xs)
	|> List.sort compare
	|> list_diff (-)
	|> List.filter ((<>) 0) in
  let xs = List.map (test2 pool) ns in
  merge (+) xs 0

let () =
  (* Needed for bytecode as plugins link against C libraries. *)
  Dynlink.allow_unsafe_modules true;
  Random.self_init ();

  let uri_r = ref None in
  let n_r = ref 1000 in
  Arg.parse
    [ "-u", Arg.String (fun s -> uri_r := Some (Uri.of_string s)),
	"URI Test against URI."; ]
    (fun _ -> raise (Arg.Bad "No positional arguments expected."))
    Sys.argv.(0);
  let uri =
    match !uri_r with
    | None ->
      Uri.of_string (try Unix.getenv "CAQTI_URI" with Not_found -> "sqlite3:")
    | Some uri -> uri in
  Lwt_main.run begin
    let pool = Caqti_lwt.connect_pool ~max_size:4 uri in
    Caqti_lwt.Pool.use
      (fun (module C : Caqti_lwt.CONNECTION) ->
	C.exec drop_q [||] >>
	C.exec create_q [||])
      pool >>
    (test2 pool !n_r >|= ignore) >>
    Caqti_lwt.Pool.use
      (fun (module C : Caqti_lwt.CONNECTION) ->
	C.exec drop_q [||])
      pool
  end
