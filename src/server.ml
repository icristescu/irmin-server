open Lwt.Syntax
open Lwt.Infix
include Server_intf
module C = Command

module Make (X : Command.S) = struct
  module Command = X
  module Store = X.Store

  type t = {
    ctx : Conduit_lwt_unix.ctx;
    uri : Uri.t;
    server : Conduit_lwt_unix.server;
    config : Irmin.config;
    repo : Store.Repo.t;
  }

  let v ?tls_config ~uri conf =
    let uri = Uri.of_string uri in
    let scheme = Uri.scheme uri |> Option.value ~default:"tcp" in
    let addr = Uri.host_with_default ~default:"127.0.0.1" uri in
    let* ctx = Conduit_lwt_unix.init ~src:addr () in
    let server =
      match String.lowercase_ascii scheme with
      | "unix" ->
          let file = Uri.path uri in
          at_exit (fun () -> try Unix.unlink file with _ -> ());
          `Unix_domain_socket (`File file)
      | "tcp" -> (
          let port = Uri.port uri |> Option.value ~default:8888 in
          match tls_config with
          | None -> `TCP (`Port port)
          | Some (`Cert_file crt, `Key_file key) ->
              `TLS
                ( `Crt_file_path crt,
                  `Key_file_path key,
                  `No_password,
                  `Port port ))
      | x -> invalid_arg ("Unknown server scheme: " ^ x)
    in
    let config = Irmin_pack_layered.config ~conf ~with_lower:true () in
    let+ repo = Store.Repo.v config in
    { ctx; uri; server; config; repo }

  let commands = Hashtbl.create 8

  let () = Hashtbl.replace_seq commands (List.to_seq Command.commands)

  let[@tailrec] rec loop repo conn client : unit Lwt.t =
    if Lwt_io.is_closed conn.Conn.ic then Lwt.return_unit
    else
      Lwt.catch
        (fun () ->
          (* Get request header (command and number of arguments) *)
          let* Request.Header.{ command } = Request.Read.header conn.Conn.ic in

          (* Get command *)
          match Hashtbl.find_opt commands command with
          | None -> Conn.err conn "unknown command"
          | Some (module Cmd : X.CMD) ->
              let* return =
                let* args =
                  Message.read conn.ic Cmd.Req.t
                  >|= Error.unwrap "Invalid arguments"
                in
                Cmd.run conn client args
              in
              Return.flush return)
        (function
          | Error.Error s ->
              (* Recover *)
              let* () = Conn.err conn s in
              Lwt_unix.sleep 0.01
          | End_of_file ->
              (* Client has disconnected *)
              let* () = Lwt_io.close conn.ic in
              Lwt.return_unit
          | exn ->
              (* Unhandled exception *)
              let* () = Lwt_io.close conn.ic in
              let s = Printexc.to_string exn in
              Logs.err (fun l -> l "Exception: %s" s);
              Lwt.return_unit)
      >>= fun () -> loop repo conn client

  let callback repo flow ic oc =
    (* Handshake check *)
    let* check =
      Lwt.catch (fun () -> Handshake.V1.check ic oc) (fun _ -> Lwt.return_false)
    in
    if not check then
      (* Hanshake failed *)
      let () =
        Logs.info (fun l -> l "Client closed because of invalid handshake")
      in
      Lwt_io.close ic
    else
      (* Handshake ok *)
      let conn = Conn.v flow ic oc in
      let branch = Store.Branch.master in
      let* store = Store.of_branch repo branch in
      let trees = Hashtbl.create 8 in
      let client = Command.{ conn; repo; branch; store; trees } in
      loop repo conn client

  let on_exn x = raise x

  let serve ?graphql { ctx; server; repo; uri; _ } =
    let () =
      match graphql with
      | Some port ->
          (* Run GraphQL server too*)
          Lwt.async (fun () ->
              let module G =
                Irmin_unix.Graphql.Server.Make
                  (Store)
                  (Irmin_unix.Graphql.Server.Remote.None)
              in
              let server = G.v repo in
              let addr = Uri.host_with_default ~default:"127.0.0.1" uri in
              let* ctx = Conduit_lwt_unix.init ~src:addr () in
              let ctx = Cohttp_lwt_unix.Net.init ~ctx () in
              let on_exn exn =
                Logs.debug (fun l ->
                    l "graphql exn: %s" (Printexc.to_string exn))
              in
              Cohttp_lwt_unix.Server.create ~on_exn ~ctx
                ~mode:(`TCP (`Port port))
                server)
      | None -> ()
    in
    Conduit_lwt_unix.serve ~ctx ~on_exn ~mode:server (callback repo)
end
