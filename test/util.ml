open Lwt.Infix
module Codec = Irmin_server_internal.Conn.Codec.Bin
module Store = Irmin_mem.KV.Make (Irmin.Contents.String)
module Client = Irmin_client_unix.Make_ext (Codec) (Store)
module Server = Irmin_server.Make_ext (Codec) (Store)

let test name f client _switch () =
  Logs.debug (fun l -> l "Running: %s" name);
  f client

let run_server s =
  let uri =
    match s with
    | `Websocket -> Uri.of_string "ws://localhost:90991"
    | `Unix_domain ->
        let dir = Unix.getcwd () in
        let sock = Filename.concat dir "test.sock" in
        Uri.of_string ("unix://" ^ sock)
    | `Tcp -> Uri.of_string "tcp://localhost:90992"
  in
  match Lwt_unix.fork () with
  | 0 ->
      let () = Irmin.Backend.Watch.set_listen_dir_hook Irmin_watcher.hook in
      let conf = Irmin_mem.config () in
      Lwt_main.run (Server.v ~uri conf >>= Server.serve);
      (0, uri)
  | n ->
      Unix.sleep 3;
      (n, uri)

let suite client all =
  List.map
    (fun (name, speed, f) ->
      Alcotest_lwt.test_case name speed (test name f client))
    all
