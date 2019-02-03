open Ast
open Instr
(*********************************************************************)

(*
  Increments its output by 1 starting at 0 when flag is true. If flag is
  false, then the rcount is reset to 0.
*)
let next_location_func flag =
  let x = ref (-1) in (
  fun () ->
    if flag then
      (x := !x + 1; !x)
    else
      (x := 0; !x)
  )
;;

(*
  Takes a return instruction and returns the register to be returned
*)
let get_register_value = function
  | I_ret r -> r
  | _ -> failwith "coding error: expected return instruction"
;;


let rec expr_to_instr (body:expr) (args:string list) (next_location:(unit -> int))
(local_map:((string, int) Hashtbl.t)) (function_names:string list):fn =

  match body with

  (* Create an integer *)
  | EInt n ->
		let r1 = `L_Reg (next_location ()) in
    [|
    	I_const (r1, (`L_Int n));
    	I_ret r1
    |]

  (* Create a string *)
	| EString str ->
		let r1 = `L_Reg (next_location ()) in
    [|
    	I_const (r1, (`L_Str str));
    	I_ret r1
    |]

  (* Attempt to read a local variable *)
	| ELocRd id ->
    (*
      checks if id has been mapped to a register in the function call, if so
		  then creates a return instruction with the mapped register; else, creates a
      return to a non-existant register.
    *)
		if (Hashtbl.mem local_map id) then  (*id has a mapping*)
			let loc = (Hashtbl.find local_map id) in (*get register value*)
			[|
				I_ret (`L_Reg loc)
			|]
		else
			failwith ("Variable - " ^ id ^ " - is not bound in this environment.")

  (* Write a value to a variable *)
	| ELocWr (id, expr) ->

		(* Build code for expr and the value *)
		let instr_for_expr, expr_value = evaluate_expression expr args next_location local_map function_names in

		let loc = if Hashtbl.mem local_map id then Hashtbl.find local_map id else next_location () in
		Hashtbl.replace local_map id loc;

		let r1 = `L_Reg loc in
		Array.append instr_for_expr
		[|
			I_mov (r1, expr_value);
			I_ret r1
		|]


  (*
  	If statement
			if exp1 then exp2 else exp3
  *)
	| EIf (exp1, exp2, exp3) ->
		(* Build code for exp1 and the value*)
		let instr_for_exp1, exp1_value = evaluate_expression exp1 args next_location local_map function_names in
		(* Build code for exp2 and exp3 *)
		let instr_for_exp2 = (expr_to_instr exp2 args next_location local_map function_names) in
		let instr_for_exp3 = (expr_to_instr exp3 args next_location local_map function_names) in

		(*if exp1 = 0 jump past code of exp2 - see how code is organized below*)
		let inst = I_if_zero (exp1_value, (Array.length instr_for_exp2)) in

		(*code_of_v1 + [|inst1|] + code_of_v2 + code_of_v3 *)
		let instrucs = Array.append instr_for_exp1 ([|inst|]) in
		let instrucs = Array.append instrucs instr_for_exp2 in
		Array.append instrucs instr_for_exp3

	(*
		While loop
			while exp1, compute block exp2
	*)
	| EWhile (exp1, exp2) ->
		(* Build code for exp1 and the value*)
		let instr_for_exp1, exp1_value = evaluate_expression exp1 args next_location local_map function_names in
		(* Build the code for exp2 - remove the return instr *)
		let instr_for_exp2, _ = evaluate_expression exp2 args next_location local_map function_names in

		let length_of_exp1_instr = Array.length instr_for_exp1 in
		let length_of_exp2_instr = Array.length instr_for_exp2 in

		(* put it all together *)
		let instrucs = Array.append instr_for_exp1 [|I_if_zero (exp1_value, (length_of_exp2_instr + 1))|] in
		let instrucs = Array.append instrucs instr_for_exp2 in
		Array.append instrucs
		[|
			(* Jump back to the top of the while loop *)
			I_jmp (-1 * (2 + length_of_exp2_instr + length_of_exp1_instr));
			I_ret (exp1_value)
		|]


	(* Compute expr1, then exp2 *)
	| ESeq (exp1, exp2) ->
		(*
			Build the code for exp1 - remove the return instr
			Build the code for exp2
			put it together
		*)
		let instr_for_exp1, _ = evaluate_expression exp1 args next_location local_map function_names in
		let instr_for_exp2 = expr_to_instr exp2 args next_location local_map function_names in
		Array.append instr_for_exp1 instr_for_exp2

	| EBinOp (exp1, op, exp2) ->
		binary_expr_to_instr exp1 exp2 op args next_location local_map function_names

	| ETabRd (exp1, exp2) ->

		let instr_for_exp1, exp1_value = evaluate_expression exp1 args next_location local_map function_names in
		let instr_for_exp2, exp2_value = evaluate_expression exp2 args next_location local_map function_names in
		let r1 = `L_Reg (next_location ())  in
		let r2 = `L_Reg (next_location ()) in
		let error_message1 = `L_Str "Error: Invalid input on table read - first argument must be a table" in
		let error_message2 = `L_Str "Error: Invalid input on table read - key does not exist" in

		Array.append (Array.append instr_for_exp1 instr_for_exp2)
		[|
			I_const (r2, (`L_Int 1));

			(* Check that the exp1 is a table *)
			I_is_tab (r1, exp1_value);
			I_sub (r1, r1, r2);
			I_if_zero (r1, 2);

			(* Error if no table *)
			I_const (r1, error_message1);
			I_halt r1;

			(* Check that the table key exists *)
			I_has_tab (r1, exp1_value, exp2_value);
			I_sub (r1, r1, r2);
			I_if_zero (r1, 2);
			
			(* Error if key doesn't exist *)
			I_const (r1, error_message2);
			I_halt r1;
			
			(* Read from the table *)
			I_rd_tab (r1, exp1_value, exp2_value);
			I_ret r1
		|]

	| ETabWr (exp1, exp2, exp3) ->
		let instr_for_exp1, exp1_value = evaluate_expression exp1 args next_location local_map function_names in
		let instr_for_exp2, exp2_value = evaluate_expression exp2 args next_location local_map function_names in
		let instr_for_exp3, exp3_value = evaluate_expression exp3 args next_location local_map function_names in
		let exp_instr = Array.append (Array.append instr_for_exp1 instr_for_exp2) instr_for_exp3 in

		Array.append exp_instr
		[|
			I_wr_tab (exp1_value, exp2_value, exp3_value);
			I_ret(exp3_value)
		|]
		(*
		let error_message = "Error: Invalid input on table read" in
		let load_message = I_const ((`L_Reg loc), (`L_Str error_message)) in
		let ihalt = I_halt (`L_Reg loc) in
		*)
		(*Array.append instrucs [|test1;is_tab;check;wr_tab;iret;load_message;ihalt|]*)

	| ECall (function_name, exp_list) ->
		call_to_instr function_name exp_list args next_location local_map function_names


and evaluate_expression expr args next_location local_map function_names =
  let code_for_expr = (expr_to_instr expr args next_location local_map function_names) in (*generate instrucs*)
  let return_position = (Array.length code_for_expr) - 1 in
  let return_register = Array.get code_for_expr return_position in (*get return inst*)
  let return_value = get_register_value return_register in (*get the register*)
  let code_for_expr = Array.sub code_for_expr 0 return_position in (*remove return inst*)
  (code_for_expr, return_value)

and binary_expr_to_instr exp1 exp2 op args next_location local_map function_names =
	
	let instr_for_exp1, exp1_value = evaluate_expression exp1 args next_location local_map function_names in
	let instr_for_exp2, exp2_value = evaluate_expression exp2 args next_location local_map function_names in
	let instrucs = Array.append instr_for_exp1 instr_for_exp2 in 
	
	let return_reg = `L_Reg (next_location ()) in
	let binary_op_instr = (
		match op with
		| BPlus -> I_add(return_reg, exp1_value, exp2_value)
		| BMinus -> I_sub(return_reg, exp1_value, exp2_value)
		| BTimes -> I_mul(return_reg, exp1_value, exp2_value)
		| BDiv -> I_div(return_reg, exp1_value, exp2_value)
		| BLt -> I_lt(return_reg, exp1_value, exp2_value)
		| BLeq -> I_leq(return_reg, exp1_value, exp2_value)
		| BEq -> I_eq(return_reg, exp1_value, exp2_value)
	) in
	
	let exp_check_reg = `L_Reg (next_location ()) in
  let sub_reg = `L_Reg (next_location ()) in 
  Array.append instrucs 
  [|
  	I_const (sub_reg, `L_Int 1);

    I_is_int (exp_check_reg, exp1_value);
    I_sub(exp_check_reg, exp_check_reg, sub_reg);
    I_if_zero (exp_check_reg, 2);
    I_const (exp_check_reg, (`L_Str "Illegal argument (1) passed to binary operator. Arguments must be integers"));
    I_halt exp_check_reg;
    
    I_is_int (exp_check_reg, exp2_value);
    I_sub(exp_check_reg, exp_check_reg, sub_reg);
    I_if_zero (exp_check_reg, 2);
    I_const (exp_check_reg, (`L_Str "Illegal argument (2) passed to binary operator. Arguments must be integers"));
    I_halt exp_check_reg;

		binary_op_instr;
    I_ret return_reg
  |]


and call_to_instr function_name exp_list args next_location local_map function_names =

	if (List.mem function_name function_names) then (

		let instrucs, regs = List.fold_left (
			fun (instrucs,regs) exp ->
				let instr_for_exp, exp_value = evaluate_expression exp args next_location local_map function_names in
				let instrucs = Array.append instrucs instr_for_exp in
				let regs = regs@[exp_value] in
				(instrucs, regs)
			) ([||],[]) exp_list in

			let instrucs = List.fold_left (fun instrucs reg_value ->
				let loc = next_location () in
				Array.append instrucs [|I_mov ((`L_Reg loc), reg_value)|]
			) instrucs regs in

			let r1_loc = next_location () in
			let r1 = `L_Reg r1_loc in
			let call_start = r1_loc - (List.length regs) in
			let call_end = r1_loc - 1 in
			Array.append instrucs
			[|
				I_const (r1, (`L_Id function_name));
				I_call (r1, call_start, call_end);
				I_ret (`L_Reg call_start)
			|]

	) else (
		built_in_call_to_instr function_name exp_list args next_location local_map function_names
	)

and built_in_call_to_instr function_name exp_list args next_location local_map function_names =

	( (* Handle not defined error *)
		if not (List.mem function_name ["mktab"; "is_i"; "is_s"; "is_t"]) then 
			failwith ("Function - " ^ function_name ^ " - is not defined")
		else ()
	); 

	if function_name = "mktab" then (
			let r1 = `L_Reg (next_location ()) in
			[| I_mk_tab r1; I_ret r1 |]
	) else (

		( (* Handle argument errors *)
			if exp_list = [] then 
				failwith ("Missing argument, function - " ^ function_name ^ " - requires 1 argument")
			else if ((List.length exp_list) > 1) then  
				failwith ("Too many arguments, function - " ^ function_name ^ " - requires 1 argument")
			else ()
		); 

		let exp::_ = exp_list in
		let instr_for_exp, exp_value = evaluate_expression exp args next_location local_map function_names in
		let r1 = `L_Reg (next_location ()) in

		let is_instr = (
			match function_name with
				| "is_i" -> I_is_int (r1, exp_value)
				| "is_s" -> I_is_str (r1, exp_value)
				| "is_t" -> I_is_tab (r1, exp_value)
				| _ -> failwith ("Function - " ^ function_name ^ " - is not defined")
		) in

		Array.append instr_for_exp
		[|
			is_instr;
			I_ret r1
		|]
	)

;;


(*
  Places the ids into the given table.
  @param [Hashtbl] tbl - The table to place the ids in
  @param [string list] ids - The ids to place in the table
  @param [unit -> int] next_location - The function for generating the location to
    map an id to within the table.
*)
let rec map_args (tbl:((string, int) Hashtbl.t)) (ids:string list) (next_location:(unit -> int)) =
	match ids with
  | [] ->
    tbl, next_location
  | id::tail ->
    (Hashtbl.replace tbl id (next_location ()));
    map_args tbl tail next_location
;;

(*
  Moves through the program and identifies all 'bad' function names.
*)
let rec extract_function_names (function_names:(string list)) (p:simpl_prog):(string list) =
	match p with
	| [] -> function_names@["to_s";"to_i";"concat";"print_string";"print_int";"size";"length"]
	| head::tail -> extract_function_names ((head.fn_name)::function_names) tail

(*
  Creates a new entry in the rubevm program for the incoming function
*)
let compile_instruction ({fn_name=name; fn_args=args; fn_body=body}:simpl_fn)
(rube_prog:prog) (next_location:(unit -> int)) (function_names:string list):prog =

	let local_map, next_location = (map_args (Hashtbl.create 8) args next_location) in

	(*turns expr into rubevm code*)
	let fn_instr = expr_to_instr body args next_location local_map function_names in 
  
  (Hashtbl.add rube_prog name fn_instr);
  rube_prog
;;

(*
  Walks over the program - instruction list - and updates the created rubevm program
  by delegating to compile_instruction
*)
let rec compile_prog_aux (p:simpl_prog) (rube_prog:prog) (function_names:string list):prog =
  match p with
	| [] -> rube_prog
	| instruc::tail ->
		let comp_instr = (compile_instruction instruc rube_prog (next_location_func true) function_names) in
    (compile_prog_aux tail comp_instr function_names)
;;


(*
  Compiles a emerarld program into emeraldbyte code.
*)
let compile_prog (p:simpl_prog):prog =
  compile_prog_aux p (Hashtbl.create (List.length p)) (extract_function_names [] p)
;;