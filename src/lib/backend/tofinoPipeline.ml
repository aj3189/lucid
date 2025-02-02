(* Tofino backend pipeline. *)
open TofinoCore

let fail_report str = Console.show_message str ANSITerminal.Red "Tofino Checker"

exception Error of string

let error s = raise (Error s)
let verbose = ref false
let do_log = ref true
let do_const_branch_vars = ref true
let cprint_endline s = if !verbose then print_endline s

let cprint_prog label tds =
  cprint_endline label;
  tdecls_to_string tds |> cprint_endline;
  cprint_endline label
;;

let mk_ir_log_dirs () =
  Core.Unix.mkdir_p !BackendLogging.irLogDir;
  Core.Unix.mkdir_p !BackendLogging.graphLogDir
;;

let ir_dump_path phasename = !BackendLogging.irLogDir ^ "/" ^ phasename ^ ".dpt"

let dbg_dump_core_prog phasename ds =
  if !do_log
  then (
    let outf = open_out (ir_dump_path phasename) in
    Printf.fprintf outf "// after phase: %s" phasename;
    Printf.fprintf outf "%s" (CorePrinting.decls_to_string ds);
    flush outf)
;;

(* perform midend passes that must be done before splitting
   the program into a control and data plane component.
   After this point, the ids of globals and actions
   should not change.  *)
(* input form: any CoreSyntax program
   output form: a CoreSyntax program with
    + no Event.delay calls
    + events and handlers have same parameter ids
    + no exit events
    + no event variables
    + each action belongs to 1 table *)
let common_midend_passes ds =
  mk_ir_log_dirs ();
  dbg_dump_core_prog "midend" ds;
  (* delete Event.delay calls and warn the user *)
  (* form: + no Event.delay calls *)
  let ds = EliminateEventCombinators.process ds in
  (*  for debugging, put the name of the event into each event parameter,
      then make sure events and handlers have the same parameter ids. *)
  (* form: + events and handlers have same parameter ids *)
  let ds = StandardizeEventParams.process ds in
  (* let ds = AlignEventParams.process ds in *)
  (* inline event variables. NOTE: this pass is broken for
        event variables that are changed conditionally in
        subsequent control flow. To fix, we should integrate
        the solution from Andrew's fork. *)
  (* form: + no event variables *)
  let ds = InlineEventVars.inline ds in
  (* make sure that each table uses unique actions *)
  (* form: + each action belongs to 1 table *)
  (* Why do this? Does something break without it? *)
  UniqueTableActions.process ds
;;

let print_if_debug ds =
  if !verbose
  then (
    print_endline "decls: ";
    let str = CorePrinting.decls_to_string ds in
    Console.report str)
;;

(* these passes are basically about converting
   expressions into simpler forms, so that every
   expression in the program can either be
   1) evaluated by a single (s)ALU (for expressions over ints)
   2) mapped directly to tcam rules (for expressions over bools) *)

(* input form: a CoreSyntax program with
    + no Event.delay calls
    + events and handlers have same parameter ids
    + no exit events
    + no event variables
    + each action belongs to 1 table
   output form: a CoreSyntax program with all of the above, and:
    + no casts of literals
    + no GTE / LTE ops
    + unit statements may only be function calls
    + no print statements
    + every match statement has a default branch
    + any variable referenced in an if or match statement's condition is a constant variable
    + every argument in a function call is either a variable or value
    + in handlers, boolean operations only occur in if condition expressions
    + in handlers, if condition expressions are in disjunctive normal form, with atoms of the form (<var> == | != <value>)
    + there are no boolean variables (1-bit ints instead)
    + integer operations are all binary operations *)
let atomic_op_form ds =
  let print_if_verbose = MidendPipeline.print_if_verbose in
  print_if_verbose "-------Eliminating interpreter-only operations--------";
  (* form: + no calls to extern functions *)
  (* form: + unit statements may only be function calls *)
  (* form: + no print statements *)
  let ds = EliminateInterpOps.eliminate_prog ds in
  print_if_debug ds;
  print_if_verbose "-------Eliminating value cast ops--------";
  (* form: + no casts of literals *)
  (* convert casts of values into values, e.g., (int<<2>>)1 --> 1w2 *)
  let ds = EliminateValueCasts.eliminate_value_casts ds in
  print_if_debug ds;
  print_if_verbose "-------Eliminating range relational ops--------";
  (* form: + no GTE / LTE ops *)
  let ds = EliminateEqRangeOps.transform ds in
  print_if_debug ds;
  print_if_verbose "-------Adding default branches--------";
  (* form: + every match statement has a default branch *)
  let ds = AddDefaultBranches.add_default_branches ds in
  MidendPipeline.print_if_debug ds;
  print_if_debug ds;
  print_if_verbose
    "-------Making variables in if / match conditions constants--------";
  (* form: + any variable referenced in an if or match statement's
           condition is not mutated in its branches.*)
  let ds = PartialSingleAssignment.const_branch_vars ds in
  (*   let ds = if (!do_const_branch_vars)
    then (PartialSingleAssignment.const_branch_vars ds)
    else (ds)
  in *)
  print_if_debug ds;
  (*   dbg_dump_core_prog "BeforeConstBranchVars" ds;
  dbg_dump_core_prog "AfterConstBranchVars" ds; *)
  (* MidendPipeline.print_if_debug ds; *)
  print_if_verbose "-------Breaking down compound expressions--------";
  (* let ds = EliminateFloods.eliminate_floods ds in  *)
  (* form: + every argument in a function call is either a variable or value *)
  let ds = PrecomputeArgs.precompute_args ds in
  (* form:
    + in handlers, boolean operations only occur in if condition expressions
    + in handlers, if condition expressions are in disjunctive normal form,
      with atoms of the form (<var> == | != <value>)
    + there are no boolean variables (1-bit ints instead) *)
  let ds = EliminateBools.do_passes ds in
  (* form: + integer operations are all binary operations *)
  let ds = NormalizeInts.do_passes ds in
  MidendPipeline.print_if_debug ds;
  ds
;;

(* normalize code and eliminate compile-time abstractions that are easier
   to deal with in tofinocore syntax *)
let tofinocore_normalization is_ingress eliminate_generates tds =
  cprint_prog "----------- initial tofinoCore program------- " tds;
  (* 1. tag match statements with many cases as solitary,
          which means they get placed into their own table.
          This could just as well be in coreSyntax.  *)
  let tds = SolitaryMatches.process tds 20 in
  (* 2. convert if statements to match statements -- this could just as well be in coreSyntax *)
  let tds = IfToMatch.process tds in
  cprint_prog "----------- after IfToMatch ------- " tds;
  (* 3. regularize memop and Array update call formats -- could be in CoreSyntax *)
  let tds = RegularizeMemops.process tds in
  cprint_prog "----------- after RegularizeMemops ------- " tds;
  (* 4. ensure that the memops to each register only reference two input variables.
          We do this in TofinoCore because CoreSyntax doesn't have "locals" that can be globally scoped. *)
  (* TofinoCore.dump_prog (!BackendLogging.irLogDir ^ "before_reg_alloc.tofinocore.dpt") tds; *)
  let tds = ShareMemopInputs.process tds in
  cprint_prog "----------- after ShareMemopInputs ------- " tds;
  (* 5. partially eliminate generate statements. Unclear if this could be done in CoreSyntax. *)
  let tds =
    if eliminate_generates then Generates.eliminate is_ingress tds else tds
  in
  cprint_prog "----------- after Generates.eliminate ------- " tds;
  TofinoCore.dump_prog
    (!BackendLogging.irLogDir ^ "/initial.before_layout.dpt")
    tds;
  (* 6. transform code so that there is only 1 match
          statement in the entire program for each table.
          This has to be in TofinoCore because it is an operation on a merged control flow. *)
  let tds = SingleTableMatch.process tds in
  (* WARNING: SingleTableMatch must come after generates.eliminate, because it
                changes the form of the program. *)
  cprint_prog "----------- after SingleTableMatch ------- " tds;
  (* 7. convert actions into functions --
          this has to be in TofinoCore because there are no functions in coreSyntax =(  *)
  let tds = ActionsToFunctions.process tds in
  cprint_prog "----------- after ActionsToFunctions ------- " tds;
  tds
;;

(* transform the tofinocore program into a
   straightline of match statements *)
let layout old_layout tds build_dir_opt =
  (* 1. compute control flow graph for main handler *)
  let cfg = CoreCfg.cfg_of_main tds in
  CoreCfg.print_cfg (!BackendLogging.graphLogDir ^ "/cfg.dot") cfg;
  (* 2. compute control dependency graph *)
  let cdg = CoreCdg.to_control_dependency_graph cfg in
  CoreCfg.print_cfg (!BackendLogging.graphLogDir ^ "/cdg.dot") cdg;
  (* 3. compute data flow / dependency graph *)
  let dfg = CoreDfg.process cdg in
  CoreDfg.print_dfg (!BackendLogging.graphLogDir ^ "/dfg.dot") dfg;
  (* 4. lay out the dfg on a pipeline of match stmt seqs *)
  print_endline "-------- layout ----------";
  (* let tds = CoreLayout.process tds dfg in *)
  let tds =
    if old_layout
    then CoreLayoutOld.process tds dfg
    else CoreLayout.process tds dfg
  in
  (* let tds = CoreLayoutNew.process_new tds dfg in *)
  (match build_dir_opt with
   | Some build_dir -> CoreLayout.profile tds build_dir
   | _ -> ());
  cprint_prog "----------- after layout ------- " tds;
  TofinoCore.dump_prog
    (!BackendLogging.irLogDir ^ "/laid_out.tofinocore.dpt")
    tds;
  (* 5. Take the statements in each match statement branch and put them into
          functions that represent actions. If a branch does a table_match,
          which cannot be executed in an action, we transform the outer match
        statement into an if statement that calls the table_match. *)
  let tds = ActionForm.process tds in
  (* 6. deduplicate actions that contain certain expensive operations. *)
  let tds = Dedup.process tds in
  TofinoCore.dump_prog
    (!BackendLogging.irLogDir ^ "/laid_out.actionform.tofinocore.dpt")
    tds;
  tds
;;

(* compile the data plane program into a P4 program.  *)
let compile_dataplane old_layout ds portspec build_dir =
  let ds = atomic_op_form ds in
  (* at this point:
      1. all the non-control flow statements in the program are
         either table_matches or atomic operations that can
         fit into a single ALU or SALU.
      2. all the control flow statements are either:
          1) match statements
          2) if statements where the expression is in a
             DNF form that is easy to convert into a match statement. *)

  (* Statements and variable names don't change much beyond this point,
     so we give everything a unique identifier. *)
  let ds = UniqueSpans.make_unique_spans ds in
  let ds = UniqueIds.make_var_names_unique ds in
  print_if_debug ds;
  (* at this point, we split the program into ingress and egress programs.
     The egress program contains all handlers tagged as egress, and all
     globals that they reference. The ingress program contains all other
     handlers and globals. Both programs receive copies of all other
     declarations. *)
  let ingress_ds, egress_ds = TofinoEgress.split_decls ds in
  (* Transform the ingress program into a "TofinoCore" program.
   *)
  let ingress_tds = tdecls_of_decls ingress_ds in
  (* TofinoCore.dump_prog (!BackendLogging.irLogDir ^ "/initial.tofinocore.dpt") tds; *)
  (* some transformation passes in tofinocore syntax *)
  let ingress_tds = tofinocore_normalization true true ingress_tds in
  (* transform program into a layout of match statements *)
  let ingress_tds = layout old_layout ingress_tds (Some build_dir) in
  (* now, if there is an egress component, package it as its
     own tofino program and do the same transformations.
     The differences are: 1) we run "add_default_egr_drop",
     which adds a drop packet command to the beginning of every egress handler
     (we want the semantics that if an egress handler doesn't explicitly
     generate an event, nothing comes out);
     2) the generates partial eliminator doesn't increment mcid for egress *)
  let egress_tds =
    if List.length egress_ds <> 0
    then
      egress_ds
      |> TofinoEgress.add_default_egr_drop
      |> tdecls_of_decls
      |> tofinocore_normalization false true
      |> fun tds -> layout old_layout tds (Some build_dir)
    else []
  in
  let tofino_prog = CoreToP4Tofino.translate portspec ingress_tds egress_tds in
  tofino_prog
;;

let compile old_layout ds portspec build_dir ctl_fn_opt =
  if !do_log
  then (
    CoreCdg.start_logging ();
    CoreDfg.start_logging ());
  let ds = common_midend_passes ds in
  (* static analysis to see if this program is compile-able *)
  InputChecks.all_checks ds;
  (* after this point, there should not be any changes
       to the globals, actions, event, or handlers defined
       in the program.
     The program should be in a form where:
      - each action is used by at most 1 table
      - event variables have been eliminated *)

  (* When we want to implement control handlers,
       this is the point at which we would split the
       program. We would compile the dataplane program
       first, then pass the data plane program and the control
       plane declarations to the control plane compiler,
       because the control plane compiler needs to know what
       multicast rules the data plane component ended up needing.*)
  (* let _, data_ds = TofinoControl.split_program 196 9 ds in *)

  (* compile to a low level p4 program *)
  let tofino_prog = compile_dataplane old_layout ds portspec build_dir in
  (* generate the python event library *)
  let py_eventlib = PyEventLib.coresyntax_to_pyeventlib ds in
  (* build the globals name directory json *)
  let globals_directory =
    P4TofinoGlobalDirectory.build_global_dir tofino_prog
    |> Yojson.Basic.pretty_to_string
  in
  (* print everything to strings *)
  let p4 = P4TofinoPrinting.p4_of_prog tofino_prog in
  let py_ctl = ControlPrinter.pyctl_of_prog tofino_prog ctl_fn_opt in
  let cpp_ctl = ControlPrinter.cppctl_of_prog tofino_prog in
  p4, cpp_ctl, py_ctl, py_eventlib, globals_directory
;;

(* DEPRECIATED compile a program with a single handler and only 1 generate
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
