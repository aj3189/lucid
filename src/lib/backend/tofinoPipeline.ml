(* Tofino backend pipeline. *)
open TofinoCore

let fail_report str = 
  Console.show_message str ANSITerminal.Red "Tofino Checker"
;;

exception Error of string
let error s = raise (Error s)

let verbose = ref false
let do_log = ref true
let do_const_branch_vars = ref true

let cprint_endline s =
  if (!verbose)
  then (print_endline s)
;;

let cprint_prog label tds =
  cprint_endline label;
  tdecls_to_string tds |> cprint_endline;
  cprint_endline label
;;

let mk_ir_log_dirs () = 
    Core.Unix.mkdir_p !BackendLogging.irLogDir;
    Core.Unix.mkdir_p !BackendLogging.graphLogDir
;;

let ir_dump_path phasename = 
  !BackendLogging.irLogDir ^ "/" ^ phasename ^ ".dpt"
;;
let dbg_dump_core_prog phasename ds =
  if (!do_log)
  then (
    let outf = (open_out (ir_dump_path phasename)) in 
    Printf.fprintf outf "// after phase: %s" phasename;
    Printf.fprintf outf "%s" (CorePrinting.decls_to_string ds);
    flush outf)
;;  


(* perform midend passes that must be done before splitting 
   the program into a control and data plane component. 
   After this point, the ids of globals and actions 
   should not change.  *)
let common_midend_passes ds =
  mk_ir_log_dirs ();
  dbg_dump_core_prog "midend" ds;
  let ds = EliminateEventCombinators.process ds in
  (* 1. make sure handlers always have the same params as their events *)
  let ds = UnifyHandlerParams.rename_event_params ds in 
  let ds = UnifyHandlerParams.unify_event_and_handler_params ds in 
  (* let ds = AlignEventParams.process ds in *)
  (* 2. convert exit events to regular events *)
  let ds = EliminateExitEvents.process ds in 
  (* 3. inline event variables. NOTE: this pass is broken for 
        event variables that are changed conditionally in 
        subsequent control flow. *)
  let ds = InlineEventVars.inline ds in 
  InlineTableActions.process ds 
;;

let print_if_debug ds =
  if (!verbose)
  then (
    print_endline "decls: ";
    let str = CorePrinting.decls_to_string ds in
    Console.report str)
;;


(* run the tofino branch of MidendPipeline.ml *)
(* these passes are basically about converting 
   expressions into simpler forms, so that every 
   expression in the program can either be 
   1) evaluated by a single (s)ALU (for expressions over ints)
   2) mapped directly to tcam rules (for expressions over bools) *)
let tofino_midend_pipeline ds =
  let print_if_verbose = MidendPipeline.print_if_verbose in
  print_if_verbose "-------Eliminating extern calls--------";
  let ds = EliminateExterns.eliminate_externs ds in 
  print_if_debug ds;
  print_if_verbose "-------Eliminating value cast ops--------";
  let ds = EliminateValueCasts.eliminate_value_casts ds in 
  print_if_debug ds;
  print_if_verbose "-------Eliminating range relational ops--------";
  let ds = EliminateEqRangeOps.transform ds in
  let ds = PoplPatches.eliminate_noncall_units ds in
  let ds = PoplPatches.delete_prints ds in
  print_if_debug ds;
  print_if_verbose "-------Adding default branches--------";
  let ds = AddDefaultBranches.add_default_branches ds in
  MidendPipeline.print_if_debug ds;
  print_if_debug ds;
  print_if_verbose "-------Breaking down compound expressions--------";
  (* ! means dref lol *)
  let ds = if (!do_const_branch_vars)
    then (PartialSingleAssignment.const_branch_vars ds)
    else (ds)
  in
  print_if_debug ds;
(*   dbg_dump_core_prog "BeforeConstBranchVars" ds;
  dbg_dump_core_prog "AfterConstBranchVars" ds; *)
  (* MidendPipeline.print_if_debug ds; *)
  print_if_verbose "-------Breaking down compound expressions--------";
  (* let ds = EliminateFloods.eliminate_floods ds in  *)
  let ds = PrecomputeArgs.precompute_args ds in
  (* get rid of boolean expressions *)
  let ds = EliminateBools.do_passes ds in
  (* convert integer operations into atomic exps *)
  let ds = NormalizeInts.do_passes ds in
  MidendPipeline.print_if_debug ds;
  (* give all the spans in a program unique IDs *)
  let ds = UniqueSpans.make_unique_spans ds in
  (* make sure that all variables in the program have unique names. 
      for non-unique ids, bring the variable's number into the name *)
  (* I bet this is breaking actions args... *)
  print_if_verbose "-------making var names unique--------";
  let ds = UniqueIds.make_var_names_unique ds in 
  print_if_debug ds;
  ds
;;

(* normalize code and eliminate compile-time abstractions that are easier 
   to deal with in tofinocore syntax *)
let tofinocore_normalization is_ingress eliminate_generates tds = 
    cprint_prog "----------- initial tofinoCore program------- " tds;
    (* 1. tag match statements with many cases as solitary, 
          i.e., they compile to their own table. *)
    let tds = SolitaryMatches.process tds 20 in
    (* 2. convert if statements to match statements. *)
    let tds = IfToMatch.process tds in 
    cprint_prog "----------- after IfToMatch ------- " tds;
    (* 3. regularize memop and Array update call formats *)
    let tds = RegularizeMemops.process tds in 
    cprint_prog "----------- after RegularizeMemops ------- " tds;
    (* 4. ensure that the memops to each register only reference two input variables *)
    (* TofinoCore.dump_prog (!BackendLogging.irLogDir ^ "before_reg_alloc.tofinocore.dpt") tds; *)
    let tds = ShareMemopInputs.process tds in 
    cprint_prog "----------- after ShareMemopInputs ------- " tds;
    (* 5. eliminate all generate statements and add invalidate calls *)
    let tds = if (eliminate_generates) then (Generates.eliminate is_ingress tds) else tds in 
    cprint_prog "----------- after Generates.eliminate ------- " tds;
    TofinoCore.dump_prog (!BackendLogging.irLogDir ^ "/initial.before_layout.dpt") tds;
    (* 6. transform code so that there is only 1 match 
          statement per user-defined table. *)
    (* WARNING: SingleTableMatch must come after generates.eliminate, because it 
                changes the form of the program. *)
    let tds = SingleTableMatch.process tds in
    cprint_prog "----------- after SingleTableMatch ------- " tds;
    (* 7. convert actions into functions *)
    let tds = ActionsToFunctions.process tds in
    cprint_prog "----------- after ActionsToFunctions ------- " tds;
    tds
;;

(* transform the tofinocore program into a 
   straightline of match statements *)
let layout old_layout tds build_dir_opt =
    (* 1. compute control flow graph for main handler *)
    let cfg = CoreCfg.cfg_of_main tds in 
    CoreCfg.print_cfg ((!BackendLogging.graphLogDir)^"/cfg.dot") cfg;
    (* 2. compute control dependency graph *)
    let cdg = CoreCdg.to_control_dependency_graph cfg in        
    CoreCfg.print_cfg ((!BackendLogging.graphLogDir)^"/cdg.dot") cdg;

    (* 3. compute data flow / dependency graph *)
    let dfg = CoreDfg.process cdg in 
    CoreDfg.print_dfg ((!BackendLogging.graphLogDir)^"/dfg.dot") dfg;
    (* 4. lay out the dfg on a pipeline of match stmt seqs *)
    print_endline "-------- layout ----------";
    (* let tds = CoreLayout.process tds dfg in *)
    let tds = if (old_layout) 
      then (CoreLayoutOld.process tds dfg)
      else (CoreLayout.process tds dfg)
    in

    (* let tds = CoreLayoutNew.process_new tds dfg in *)
    (match build_dir_opt with 
        | Some build_dir -> CoreLayout.profile tds build_dir;
        | _ -> ()
    );
    cprint_prog "----------- after layout ------- " tds;
    TofinoCore.dump_prog (!BackendLogging.irLogDir ^ "/laid_out.tofinocore.dpt") tds;
    (* 5. put branches of match statements into actions. If a branch calls a 
           table_match, which cannot be put into an action, then 
           rewrite the match statement as an if expression. *)
    let tds = ActionForm.process tds in 
    (* 6. deduplicate actions that contain certain expensive operations. *)
    let tds = Dedup.process tds in 
    TofinoCore.dump_prog (!BackendLogging.irLogDir ^ "/laid_out.actionform.tofinocore.dpt") tds;
    tds 
;;

let compile_dataplane old_layout ds portspec build_dir =
  (* compile the data plane program into a P4 program.  *)
  let ds = tofino_midend_pipeline ds in 

  (* egress_ds are the handlers and globals to be placed in egress *)
  let ingress_ds, egress_ds = TofinoEgress.split_decls ds in

  cprint_endline "starting transformations";
  (* translate into tofinocore -- basically just coresyntax 
     with labeled statements, shared variables,and a main handler *)
  let ingress_tds = tdecls_of_decls ingress_ds in 
  (* TofinoCore.dump_prog (!BackendLogging.irLogDir ^ "/initial.tofinocore.dpt") tds; *)
  (* some transformation passes in tofinocore syntax *)
  let ingress_tds = tofinocore_normalization true true ingress_tds in 
  (* transform program into a layout of match statements *)
  let ingress_tds = layout old_layout ingress_tds (Some build_dir) in 

  (* now, if there is an egress component, package it as its 
     own tofino program and do the same transformations. 
     The differences are: 1) we do add_default_egr_drop, 
     which adds a drop packet command to the beginning of every egress handler; 
     2) the generates partial eliminator doesn't increment mcid for egress *)
  let egress_tds = 
    if ((List.length egress_ds) <> 0) then (
         egress_ds
      |> TofinoEgress.add_default_egr_drop
      |> tdecls_of_decls  
      |> tofinocore_normalization false true
      |> (fun tds -> layout old_layout tds (Some build_dir)))
    else ([])
  in
  let tofino_prog = CoreToP4Tofino.translate portspec ingress_tds egress_tds  in 
  tofino_prog
;;
let compile old_layout ds portspec build_dir ctl_fn_opt = 
    if (!do_log) then (
        CoreCdg.start_logging ();
        CoreDfg.start_logging ();
    );
    (* all passes that rename or create 
       globals or actions must happen before the 
       data / control plane split *)
    let ds = common_midend_passes ds in
    (* static analysis to see if this program is compile-able *)
    InputChecks.all_checks ds;

    (* at the beginning of the midend, we split the program 
    into a control program, which gets compiled to C / python, 
    and a data plane program, that gets compiled into P4. *)
    let _, data_ds = TofinoControl.split_program 196 9 ds in

    (* Left off here: generate python or C from the control 
       program. 
       tricky part is table / register manipulation *)


    (* first we compile the tofino program, because it will generate 
       some setup commands for the control plane to run *)
    let tofino_prog = compile_dataplane old_layout data_ds portspec build_dir in

    (* next, compile the control program (TODO) *)


    (* build the globals directory *)
    let globals_directory = P4TofinoGlobalDirectory.build_global_dir tofino_prog 
      |> Yojson.Basic.pretty_to_string 
    in
(*     print_endline ("---------- globals ----------  ");
    print_endline globals_directory; *)
    (* print data and control plane programs *)
    let p4 = P4TofinoPrinting.p4_of_prog tofino_prog in 
    let py_ctl = ControlPrinter.pyctl_of_prog tofino_prog ctl_fn_opt in
    let cpp_ctl = ControlPrinter.cppctl_of_prog tofino_prog in
    let py_eventlib = PyEventLib.coresyntax_to_pyeventlib ds in
    p4, cpp_ctl, py_ctl, py_eventlib, globals_directory
;;

(* compile a program with a single handler and only 1 generate 
   statement into a p4 control block, to be used as a module 
   in other P4 programs. *)
let compile_handler_block ds =
    InputChecks.all_checks ds;
    let ds = common_midend_passes ds in
    let tds = tdecls_of_decls ds in 
    let tds = tofinocore_normalization true false tds in 
    let tds = layout false tds None in 
    let p4decls = CoreToP4Tofino.translate_to_control_block tds in 
    P4TofinoPrinting.string_of_decls p4decls |> P4TofinoPrinting.doc_to_string
;;
