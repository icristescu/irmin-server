module type S = sig
  module Conn : Conn.S

  module Store : Irmin.Generic_key.S
  (** Irmin [Store] type *)

  (** [Tree] wraps [Store.Tree] to avoid encoding/decoding trees more than needed *)
  module Tree :
    Tree.S
      with type kinded_key = Store.Tree.kinded_key
       and type concrete = Store.Tree.concrete

  (** Commits *)
  module Commit :
    Commit.S
      with type hash = Store.Hash.t
       and type key = Store.commit_key
       and type tree = Tree.t
       and module Info = Store.Info

  (** Used to track information about the server *)
  module Server_info : sig
    type t = { start_time : float }
  end

  type context = {
    conn : Conn.t;
    config : Irmin.Backend.Conf.t;
    repo : Store.Repo.t;
    mutable branch : Store.branch;
    mutable store : Store.t;
    trees : (int, Store.tree) Hashtbl.t;
    mutable watch : Store.watch option;
    mutable branch_watch : Store.Backend.Branch.watch option;
  }
  (** [context] is passed to every command as the first argument *)

  module type CMD = sig
    type req
    type res

    val req_t : req Irmin.Type.t
    val res_t : res Irmin.Type.t
    val name : string

    val run :
      Conn.t -> context -> Server_info.t -> req -> res Conn.Return.t Lwt.t
  end

  type t = (module CMD)
  (** Command type *)

  val name : t -> string
  (** Get the name of a command *)

  val of_name : string -> t
  (** Find a command by name, the name should be lowercase *)

  val commands : (string * t) list
  (** A list of all registered commands *)

  module Commands : sig
    module Backend : sig
      module Schema : Irmin.Schema.S
      module Hash : Irmin.Hash.S with type t = Schema.Hash.t

      module Contents : sig
        type key = Store.Backend.Contents.key
        type value = Store.Backend.Contents.value
        type hash = Store.Backend.Contents.hash

        module Mem : CMD with type req = key and type res = bool
        module Find : CMD with type req = key and type res = value option
        module Add : CMD with type req = value and type res = key
        module Unsafe_add : CMD with type req = hash * value and type res = key
        module Index : CMD with type req = hash and type res = key option

        module Merge :
          CMD
            with type req = key option option * key option * key option
             and type res = (key option, Irmin.Merge.conflict) Result.t
      end

      module Node : sig
        type key = Store.Backend.Node.key
        type value = Store.Backend.Node.value
        type hash = Store.Backend.Node.hash

        module Mem : CMD with type req = key and type res = bool
        module Find : CMD with type req = key and type res = value option
        module Add : CMD with type req = value and type res = key
        module Unsafe_add : CMD with type req = hash * value and type res = key
        module Index : CMD with type req = hash and type res = key option

        module Merge :
          CMD
            with type req = key option option * key option * key option
             and type res = (key option, Irmin.Merge.conflict) Result.t
      end

      module Commit : sig
        type key = Store.Backend.Commit.key
        type value = Store.Backend.Commit.value
        type hash = Store.Backend.Commit.hash

        module Mem : CMD with type req = key and type res = bool
        module Find : CMD with type req = key and type res = value option
        module Add : CMD with type req = value and type res = key
        module Unsafe_add : CMD with type req = hash * value and type res = key
        module Index : CMD with type req = hash and type res = key option

        module Merge :
          CMD
            with type req =
              Store.Info.t * (key option option * key option * key option)
             and type res = (key option, Irmin.Merge.conflict) Result.t
      end

      module Branch : sig
        type key = Store.Backend.Branch.key
        type value = Store.Backend.Branch.value

        module Mem : CMD with type req = key and type res = bool
        module Find : CMD with type req = key and type res = value option
        module Set : CMD with type req = key * value and type res = unit

        module Test_and_set :
          CMD
            with type req = key * value option * value option
             and type res = bool

        module Remove : CMD with type req = key and type res = unit
        module List : CMD with type req = unit and type res = key list
        module Clear : CMD with type req = unit and type res = unit

        module Watch :
          CMD with type req = (key * value) list option and type res = unit

        module Watch_key :
          CMD with type req = value option * key and type res = unit

        module Unwatch : CMD with type req = unit and type res = unit
      end
    end

    (** Check connectivity *)
    module Ping : CMD with type req = unit and type res = unit

    (* Branch *)

    (** Set the current branch for a client *)
    module Set_current_branch :
      CMD with type req = Store.branch and type res = unit

    (** Get the current branch for a client *)
    module Get_current_branch :
      CMD with type req = unit and type res = Store.branch

    (** Export repo *)
    module Export : CMD with type req = int option and type res = Store.slice

    (** Import repo *)
    module Import : CMD with type req = Store.slice and type res = unit

    (* Tree *)
    module Tree : sig
      type t = Tree.t

      (** Create an empty tree *)
      module Empty : CMD with type req = unit and type res = Tree.t

      (** Add a value to a tree *)
      module Add :
        CMD
          with type req = Tree.t * Store.path * Store.contents
           and type res = Tree.t

      module Save :
        CMD
          with type req = Tree.t
           and type res =
            [ `Contents of Store.contents_key | `Node of Store.node_key ]

      module Of_path :
        CMD with type req = Store.path and type res = Tree.t option

      module Of_hash :
        CMD with type req = Store.hash and type res = Tree.t option

      module Of_commit :
        CMD with type req = Store.hash and type res = Tree.t option

      (** Add multiple trees/values to a tree *)
      module Batch_apply :
        CMD
          with type req =
            Tree.t
            * (Store.path
              * [ `Contents of
                  [ `Hash of Store.hash | `Value of Store.contents ]
                  * Store.metadata option
                | `Tree of Tree.t ]
                option)
              list
           and type res = Tree.t

      (** Add a tree to a tree *)
      module Add_tree :
        CMD with type req = Tree.t * Store.path * Tree.t and type res = Tree.t

      (** Remove path from a tree *)
      module Remove :
        CMD with type req = Tree.t * Store.path and type res = Tree.t

      (** Find a value from a tree *)
      module Find :
        CMD
          with type req = Tree.t * Store.path
           and type res = Store.contents option

      (** Find a tree from a tree *)
      module Find_tree :
        CMD with type req = Tree.t * Store.path and type res = Tree.t option

      (** Deallocate a single tree *)
      module Cleanup : CMD with type req = Tree.t and type res = unit

      (** Convert tree to concrete representation *)
      module To_local : CMD with type req = Tree.t and type res = Tree.concrete

      (** Check if a path is set to a value in a tree *)
      module Mem : CMD with type req = Tree.t * Store.path and type res = bool

      (** Check if a path is set to a tree *)
      module Mem_tree :
        CMD with type req = Tree.t * Store.path and type res = bool

      (** List items in one level of a tree *)
      module List :
        CMD
          with type req = Tree.t * Store.path
           and type res = (Store.Path.step * [ `Contents | `Tree ]) list

      (** Get tree hash *)
      module Hash : CMD with type req = Tree.t and type res = Store.Hash.t

      (** Get tree key *)
      module Key :
        CMD with type req = Tree.t and type res = Store.Tree.kinded_key

      (** Deallocate all trees *)
      module Cleanup_all : CMD with type req = unit and type res = unit

      (** Merge with another tree *)
      module Merge :
        CMD with type req = Tree.t * Tree.t * Tree.t and type res = Tree.t
    end

    (* Store *)
    module Store : sig
      (** Find a value in the store *)
      (*module Find :
        CMD with type req = Store.path and type res = Store.contents option*)

      (** Add a new value to the store *)
      (*module Set :
        CMD
          with type req = Store.path * Store.Info.t * Store.contents
           and type res = unit*)

      (** Add a value to the store if [test] matches the existing value *)
      (*module Test_and_set :
        CMD
          with type req =
            Store.path
            * Store.Info.t
            * (Store.contents option * Store.contents option)
           and type res = unit*)

      (** Remove a value from the store *)
      (*module Remove :
        CMD with type req = Store.path * Store.Info.t and type res = unit*)

      (** Get a tree from the store *)
      (*module Find_tree :
        CMD with type req = Store.path and type res = Tree.t option*)

      (** Add a tree to the store *)
      (*module Set_tree :
        CMD
          with type req = Store.path * Store.Info.t * Tree.t
           and type res = Tree.t*)

      (** Add a tree to the store if [test] matches the existing tree *)
      (*module Test_and_set_tree :
        CMD
          with type req =
            Store.path * Store.Info.t * (Tree.t option * Tree.t option)
           and type res = Tree.t option*)

      (** Check for the existence of a value in the store *)
      module Mem : CMD with type req = Store.path and type res = bool

      (** Check for the existence of a tree in the store *)
      module Mem_tree : CMD with type req = Store.path and type res = bool

      (** Merge the current branch with another branch *)
      (*module Merge :
        CMD with type req = Store.Info.t * Store.Branch.t and type res = unit*)

      (** Merge the current branch with a commit *)
      (*module Merge_commit :
        CMD with type req = Store.Info.t * Commit.t and type res = unit*)

      (** Get a list of commits that modified a specific path *)
      (*module Last_modified :
        CMD with type req = Store.path and type res = Commit.t list*)
    end
  end
end

module type Command = sig
  module type S = S

  module Make
      (IO : Conn.IO)
      (Codec : Conn.Codec.S)
      (Store : Irmin.Generic_key.S) :
    S
      with module Store = Store
       and type Tree.kinded_key = Store.Tree.kinded_key
       and type Tree.concrete = Store.Tree.concrete
       and module Conn.IO = IO
end
