open Syntax
open SyntaxUtils
open Collections
open Batteries

(* Region-like levels for efficient implementation of type generalization
   code following http://okmij.org/ftp/ML/generalization.html#levels
*)
(* Since we currently only generalize at DFuns, the whole level setup is
   overkill, but it'll be handy if we get more functional later on. *)
let current_level = ref 0
let enter_level () = incr current_level
let leave_level () = decr current_level
let level () = !current_level
let level_reset () = current_level := 0

(* Create new unbound TVars of each type *)
let fresh_tvar name = TVar (ref (Unbound (Id.fresh name, level ())))
let fresh_size ?(name = "sz") () = IVar (fresh_tvar name)
let fresh_effect ?(name = "eff") () = FVar (fresh_tvar name)

let fresh_type ?(name = "a") () =
  ty_eff (TQVar (fresh_tvar name)) (fresh_effect ())
;;

let error_sp sp msg = Console.error_position sp msg
let strip_links ty = { ty with raw_ty = TyTQVar.strip_links ty.raw_ty }

type modul =
  { sizes : IdSet.t
  ; vars : ty IdMap.t
  ; user_tys : (sizes * ty) IdMap.t
  ; constructors : func_ty IdMap.t
  ; submodules : modul IdMap.t
  }

let empty_modul =
  { sizes = IdSet.empty
  ; vars = IdMap.empty
  ; user_tys = IdMap.empty
  ; constructors = IdMap.empty
  ; submodules = IdMap.empty
  }
;;

(* Not sure which set of functions will end up being the most useful *)
(* let modul_sizes m = m.sizes
let modul_vars m = m.vars
let modul_tys m = m.user_tys
let modul_constrs m = m.constructors *)

let lookup_modul_size id m = IdSet.find_opt id m.sizes
let lookup_modul_var id m = IdMap.find_opt id m.vars
let lookup_modul_ty id m = IdMap.find_opt id m.user_tys
let lookup_modul_constr id m = IdMap.find_opt id m.constructors

type env =
  { (*** Global information ***)
    current_modul : modul
  ; parents : modul list
  ; record_labels : ty StringMap.t (* Maps labels to the gty with that label *)
  ; (*** Information we use while typechecking function/handler bodies ***)
    locals : ty IdMap.t
  ; current_effect : effect
  ; (* Maps vector index vars to their max size and an alpha-renamed cid *)
    indices : (id * size) IdMap.t
  ; constraints : constr list
  ; ret_ty : ty option (* Some iff we're in a function body *)
  ; ret_effects : effect list (* All the effects we `return`ed at *)
  ; returned : bool (* If we ran into a return statement *)
  ; in_global_def : bool (* True if we're able to use constructors *)
  }

let empty_env =
  { locals = IdMap.empty
  ; parents = []
  ; indices = IdMap.empty
  ; current_effect = FZero
  ; constraints = []
  ; ret_ty = None
  ; ret_effects = []
  ; returned = false
  ; record_labels = StringMap.empty
  ; in_global_def = false
  ; current_modul = empty_modul
  }
;;

let default_env =
  let modules =
    List.map
      (fun (id, tys, defs, constructors) ->
        let vars =
          List.fold_left
            (fun acc (r : InterpState.State.global_fun) ->
              IdMap.add (Cid.first_id r.cid) r.ty acc)
            IdMap.empty
            defs
        in
        let constructors =
          List.fold_left
            (fun acc (cid, fty) -> IdMap.add (Cid.first_id cid) fty acc)
            IdMap.empty
            constructors
        in
        let user_tys =
          List.fold_left
            (fun acc (tid, sizes, ty) -> IdMap.add tid (sizes, ty) acc)
            IdMap.empty
            tys
        in
        id, { empty_modul with vars; constructors; user_tys })
      Builtins.builtin_modules
  in
  let submodules =
    List.fold_left
      (fun acc (id, modul) -> IdMap.add id modul acc)
      IdMap.empty
      modules
  in
  let global_vars =
    List.fold_left
      (fun acc (id, ty) -> IdMap.add id ty acc)
      IdMap.empty
      Builtins.builtin_vars
  in
  let current_modul =
    { empty_env.current_modul with submodules; vars = global_vars }
  in
  { empty_env with current_modul }
;;

(* Helper function, you probably don't want to call this directly. We expect
   f to be one of the "lookup_modul_xxx" functions from above. *)
let lookup_any span lookup env cid =
  match cid with
  | Id id ->
    (* Walk up through parents, checking at each step *)
    List.find_map_opt (lookup id) (env.current_modul :: env.parents)
  | Compound (id, cid) ->
    (* Walk up until we find a module with the appropriate name *)
    let starting_submodule =
      List.find_map_opt
        (fun m -> IdMap.find_opt id m.submodules)
        (env.current_modul :: env.parents)
    in
    if starting_submodule = None
    then
      Console.error_position span @@ "Unkown module " ^ Printing.id_to_string id;
    (* Now walk down through that module's submodules until we hit the end of the cid *)
    let _, final_modul =
      List.fold_left
        (fun (path, m) id ->
          match IdMap.find_opt id m.submodules with
          | Some m -> id :: path, m
          | None ->
            Console.error_position span
            @@ "Unkown module "
            ^ BatString.concat
                "."
                (List.rev_map Printing.id_to_string (id :: path)))
        ([id], env.current_modul)
        (Cid.to_ids cid)
    in
    (* Finally, do the appropriate lookup in the module we ended up at *)
    lookup id final_modul
;;

let size_exists span env cid =
  match lookup_any span lookup_modul_size env cid with
  | None -> false
  | _ -> true
;;

let lookup_ty span env cid =
  match lookup_any span lookup_modul_ty env cid with
  | Some x -> x
  | None ->
    Console.error_position span @@ "Unknown type " ^ Printing.cid_to_string cid
;;

let lookup_var span env cid =
  let local_val =
    match cid with
    | Id id -> IdMap.find_opt id env.locals
    | _ -> None
  in
  match local_val with
  | Some t -> t
  | None ->
    let lookup_fun id m =
      match lookup_modul_var id m with
      | Some t -> Some t
      | None ->
        (match lookup_modul_constr id m with
        | None -> None
        | Some t ->
          if env.in_global_def || not (is_global t.ret_ty)
          then Some (ty (TFun t))
          else
            error_sp
              span
              "Cannot call global constructor except in global definitions or \
               other constructors")
    in
    (match lookup_any span lookup_fun env cid with
    | Some t -> t
    | None -> error_sp span @@ "Unbound variable " ^ Printing.cid_to_string cid)
;;

(* Drops the last n constraints in the second environment and returns
   the rest. For use after if/match statments, where the result after
   each side constains all the constraints from the original env plus
   maybe some more. This is a quick way of preventing duplicates. *)
let drop_constraints (env : env) (env' : env) =
  List.take
    (List.length env'.constraints - List.length env.constraints)
    env'.constraints
;;

let drop_ret_effects (env : env) (env' : env) =
  List.take
    (List.length env'.ret_effects - List.length env.ret_effects)
    env'.ret_effects
;;

let wrap e ety = { e with ety }

let textract (env, e) =
  match e.ety with
  | None -> failwith "internal error (textract)"
  | Some ty -> env, e, ty
;;

(** Inference and well-formedness for memops. They have a lot of restrictions
    on them: They must have exactly two arguments, an int<<'a>> and a 'b, plus
    their bodies follow a restricted grammar *)

(* An expression in a memop may use an unlimited number of binops, but
   only some are allowed. Furthermore, each parameter can appear only once in the
   expression; all other arguments must be constants. *)
let check_e cid1 cid2 allowed (seen1, seen2) exp =
  let rec aux (seen1, seen2) e =
    match e.e with
    | EVal _ | EInt _ -> seen1, seen2
    | EVar cid when Cid.equals cid cid1 ->
      if not seen1
      then true, seen2
      else
        error_sp
          exp.espan
          ("Parameter "
          ^ Cid.to_string cid
          ^ " appears more than once in memop expression")
    | EVar cid when Cid.equals cid cid2 ->
      if not seen2
      then seen1, true
      else
        error_sp
          exp.espan
          ("Parameter "
          ^ Cid.to_string cid
          ^ " appears more than once in memop expression")
    | EVar _ -> seen1, seen2
    | EOp (op, [e1; e2]) ->
      if allowed op
      then (
        let seen_vars = aux (seen1, seen2) e1 in
        aux seen_vars e2)
      else
        error_sp
          e.espan
          ("Disallowed operation in memop expression" ^ Printing.exp_to_string e)
    | _ ->
      error_sp
        e.espan
        ("Disallowed expression in memop expression: "
        ^ Printing.exp_to_string e)
  in
  aux (seen1, seen2) exp
;;

(* Similar to check_return, except the test of the body also conditionals *)
let check_test id1 id2 exp =
  let check_e = check_e (Id id1) (Id id2) in
  let allowed = function
    | Plus | Sub -> true
    | _ -> false
  in
  match exp.e with
  | EOp ((Eq | Neq | Less | More), [e1; e2]) ->
    let seen_vars1 = check_e allowed (false, false) e1 in
    ignore @@ check_e allowed seen_vars1 e2
  | _ -> ignore @@ check_e allowed (false, false) exp
;;

(* Construct the type for an event creation function given its constraints
   and parameters *)
let mk_event_ty constrs params =
  let eff = FVar (QVar (Id.fresh "start")) in
  ty
  @@ TFun
       { arg_tys = List.map snd params
       ; ret_ty = ty TEvent
       ; start_eff = eff
       ; end_eff = eff
       ; constraints = ref constrs
       }
;;

(* Given a printf statement, return the list of expected types for its arguments
   based on the formatters in the string *)
let extract_print_tys span (s : string) =
  let rec aux acc chars =
    match chars with
    | [] -> acc
    | '\\' :: '%' :: tl -> aux acc tl
    | '%' :: 'b' :: tl -> aux (TBool :: acc) tl
    | '%' :: 'd' :: tl -> aux (TInt (fresh_size ()) :: acc) tl
    | '%' :: _ -> error_sp span "Invalid % in printf string"
    | _ :: tl -> aux acc tl
  in
  List.rev @@ aux [] (String.to_list s)
;;

let rec validate_size span env size =
  match STQVar.strip_links size with
  | IUser cid ->
    if not (size_exists span env cid)
    then error_sp span @@ "Unknown size " ^ Printing.cid_to_string cid
  | ISum (sizes, n) ->
    if n < 0 then error_sp span @@ "Size sum had negative number?";
    List.iter (validate_size span env) sizes
  | IConst _ | IVar _ -> ()
;;

(* Turn a user's constraint specification into a list of actual constraints
   on the effects of the parameters, as well as a starter list of ending effects
*)
let spec_to_constraints (env : env) sp start_eff (params : params) specs =
  let lookup_effect env cid =
    if Cid.names cid = ["start"]
    then start_eff
    else (
      let ty = lookup_var sp env cid in
      if not (is_global ty)
      then
        error_sp sp
        @@ "Variable "
        ^ Printing.cid_to_string cid
        ^ " is not obviously global and cannot appear in a constraint."
      else ty.teffect)
  in
  let env =
    List.fold_left
      (fun env (id, ty) -> { env with locals = IdMap.add id ty env.locals })
      env
      params
  in
  let constraints =
    List.concat
    @@ List.map
         (function
           | CSpec lst ->
             let left = List.take (List.length lst - 1) lst in
             let right = List.tl lst in
             List.map2
               (fun (cid1, cmp) (cid2, _) ->
                 let left_eff =
                   match cmp with
                   | SpecLess -> FSucc (lookup_effect env cid1)
                   | SpecLeq -> lookup_effect env cid1
                 in
                 CLeq (left_eff, lookup_effect env cid2))
               left
               right
           | CEnd _ -> [])
         specs
  in
  let end_eff =
    let ends =
      List.filter_map
        (function
          | CEnd id -> Some (FSucc (lookup_effect env id))
          | CSpec _ -> None)
        specs
    in
    match ends with
    | [] -> None
    | [hd] -> Some hd
    | _ -> error_sp sp @@ "Cannot specify more than one end constraint"
  in
  constraints, end_eff
;;

let add_record_label env span recty l =
  let l = Id.name l in
  match StringMap.find_opt l env.record_labels with
  | None -> { env with record_labels = StringMap.add l recty env.record_labels }
  | Some ty ->
    error_sp span
    @@ Printf.sprintf
         "The label %s already exists in type %s"
         l
         (Printing.ty_to_string ty)
;;

type loop_subst = (id * int) * (id * effect)

let subst_loop =
  object (self)
    inherit [_] s_map

    method! visit_FIndex (env : loop_subst) id eff =
      let eff = self#visit_effect env eff in
      let target, n = fst env in
      if Id.equal id target
      then if n = 0 then FProj eff else FSucc (FProj eff)
      else FIndex (id, eff)

    method! visit_FVar (env : loop_subst) tqv =
      let target, eff = snd env in
      match tqv with
      | TVar { contents = Unbound (id, _) } when Id.equal id target -> eff
      | _ -> FVar (self#visit_tqvar self#visit_effect env tqv)
  end
;;

let drop_indexes target eff =
  let rec aux lst =
    match lst with
    | [] -> []
    | (Some id, _) :: _ when Id.equal id target -> []
    | hd :: tl -> hd :: aux tl
  in
  let base, lst = unwrap_effect eff in
  let lst = aux lst in
  wrap_effect base lst
;;

(* TODO: If we still have TyperModules, this might fit better there *)
let rec modul_of_interface span env interface =
  let aux acc intf =
    match intf.ispec with
    | InSize id -> { acc with sizes = IdSet.add id acc.sizes }
    | InVar (id, ty) -> { acc with vars = IdMap.add id ty acc.vars }
    | InTy (id, sizes, tyo, b) ->
      let ty =
        match tyo with
        | Some ty ->
          ty
          (* FIXME: We need to ensure these TNames are always unique. Maybe. *)
        | None -> ty @@ TName (Id id, sizes, b)
      in
      { acc with user_tys = IdMap.add id (sizes, ty) acc.user_tys }
    | InConstr (id, ty, params) ->
      let start_eff = fresh_effect () in
      let fty =
        { arg_tys = List.map snd params
        ; ret_ty = ty
        ; start_eff
        ; end_eff = start_eff
        ; constraints = ref []
        }
        |> normalize_tfun
      in
      { acc with constructors = IdMap.add id fty acc.constructors }
    | InFun (id, ret_ty, constrs, params) ->
      let start_eff = fresh_effect () in
      let constrs, end_eff =
        spec_to_constraints env span start_eff params constrs
      in
      let end_eff = Option.default start_eff end_eff in
      let fty =
        { arg_tys = List.map snd params
        ; ret_ty
        ; start_eff
        ; end_eff
        ; constraints = ref constrs
        }
        |> normalize_tfun
      in
      { acc with vars = IdMap.add id (ty @@ TFun fty) acc.vars }
    | InEvent (id, constrs, params) ->
      let start_eff = fresh_effect () in
      let constrs, _ = spec_to_constraints env span start_eff params constrs in
      let fty =
        { arg_tys = List.map snd params
        ; ret_ty = ty TEvent
        ; start_eff
        ; end_eff = start_eff
        ; constraints = ref constrs
        }
        |> normalize_tfun
      in
      { acc with vars = IdMap.add id (ty @@ TFun fty) acc.vars }
    | InModule (id, interface) ->
      { acc with
        submodules =
          IdMap.add id (modul_of_interface span env interface) acc.submodules
      }
  in
  List.fold_left aux empty_modul interface
;;

(* Replace TNames with their definitions, according to the map provided in env *)
let subst_interface_tys target sizes ty modul =
  let v =
    object
      inherit [_] s_map as super

      method! visit_ty (target, sizes', ty') ty =
        match ty.raw_ty with
        | TName (Id id, sizes, _) when Id.equal id target ->
          let replaced_ty =
            ReplaceUserTys.subst_sizes
              ty.tspan
              (Id id)
              ty'.raw_ty
              (ReplaceUserTys.extract_ids ty.tspan sizes')
              sizes
          in
          { ty with raw_ty = replaced_ty; teffect = ty'.teffect }
        | _ -> super#visit_ty (target, sizes', ty') ty
    end
  in
  let env = target, sizes, ty in
  let rec subst_modul modul =
    { modul with
      vars = IdMap.map (v#visit_ty env) modul.vars
    ; user_tys =
        (* FIXME: The handling of sizes here might be wrong *)
        IdMap.map (fun (_, ty) -> sizes, v#visit_ty env ty) modul.user_tys
    ; constructors = IdMap.map (v#visit_func_ty env) modul.constructors
    ; submodules = IdMap.map subst_modul modul.submodules
    }
  in
  subst_modul modul
;;

(* FIXME: Do we need to pass any optional args to equiv_ty? *)
let rec equiv_modul m1 m2 =
  let cmp_user_tys (szs1, ty1) (szs2, ty2) =
    let szs1, ty1 =
      let norm = normalizer () in
      List.map (norm#visit_size ()) szs1, norm#visit_ty () ty1
    in
    let szs2, ty2 =
      let norm = normalizer () in
      List.map (norm#visit_size ()) szs2, norm#visit_ty () ty2
    in
    List.length szs1 = List.length szs2 && equiv_ty ty1 ty2
  in
  let cmp_ftys fty1 fty2 = equiv_raw_ty (TFun fty1) (TFun fty2) in
  IdSet.equal m1.sizes m2.sizes
  && IdMap.equal equiv_ty m1.vars m2.vars
  && IdMap.equal cmp_user_tys m1.user_tys m2.user_tys
  && IdMap.equal cmp_ftys m1.constructors m2.constructors
  && IdMap.equal equiv_modul m1.submodules m2.submodules
;;

(* Validate that the module matches the interface, and return the interface modul
   to be added to the environment *)
let add_interface span env intf modul =
  let intf_modul = modul_of_interface span env intf in
  let subst_tys id (_, ty) acc =
    match ty.raw_ty with
    | TName (Id id', _, _) when Id.equal id id' ->
      (* Abstract type in interface, replace it with its definition *)
      let sizes', ty' =
        match IdMap.find_opt id modul.user_tys with
        | Some x -> x
        | None ->
          Console.error_position span
          @@ "Type "
          ^ Printing.id_to_string id
          ^ " is declared in interface but not in module body."
      in
      subst_interface_tys id sizes' ty' acc
    | _ -> acc
  in
  let subst_modul = IdMap.fold subst_tys intf_modul.user_tys intf_modul in
  if not (equiv_modul subst_modul modul)
  then
    Console.error_position
      span
      "Module interface does not match declarations in body";
  (* Return the un-substed version *)
  intf_modul
;;
