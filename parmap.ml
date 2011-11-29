(**************************************************************************)
(* ParMap: a simple library to perform Map computations on a multi-core   *)
(*                                                                        *)
(*  Author(s):  Marco Danelutto, Roberto Di Cosmo                         *)
(*                                                                        *)
(*  This library is free software: you can redistribute it and/or modify  *)
(*  it under the terms of the GNU Lesser General Public License as        *)
(*  published by the Free Software Foundation, either version 2 of the    *)
(*  License, or (at your option) any later version.  A special linking    *)
(*  exception to the GNU Lesser General Public License applies to this    *)
(*  library, see the LICENSE file for more information.                   *)
(**************************************************************************)

open ExtLib

(* sequence type, subsuming lists and arrays *)

type 'a sequence = L of 'a list | A of 'a array;;

let debug_enabled = ref false;;

let log_dir = ref (Printf.sprintf "/tmp/.parmap.%d" (Unix.getpid ()))

let debug fmt =
  Printf.kprintf (
    if !debug_enabled then begin
      (fun s -> Format.eprintf "[Parmap]: %s@." s)
    end else ignore
  ) fmt

let info fmt =
  Printf.kprintf (fun s -> Format.eprintf "[Parmap]: %s@." s) fmt

(* utils *)

(* would be [? a | a <- startv--endv] using list comprehension from Batteries *)

let ext_intv startv endv =
  let s,e = (min startv endv),(max startv endv) in
  let rec aux acc = function n -> if n=s then n::acc else aux (n::acc) (n-1)
  in aux [] e
;;

(* find index of the first occurrence of an element in a list *)

let index_of e l =
  let rec aux = function
      ([],_) -> raise Not_found
    | (a::r,n) -> if a=e then n else aux (r,n+1)
  in aux (l,0)
;;

(* freopen emulation, from Xavier's suggestion on OCaml mailing list *)

let reopen_out outchan fname =
  flush outchan;
  if not(Sys.file_exists !log_dir) then Unix.mkdir !log_dir 0o777 ;
  let filename = Filename.concat !log_dir fname in
  let fd1 = Unix.descr_of_out_channel outchan in
  let fd2 = Unix.openfile filename [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o666 in
  Unix.dup2 fd2 fd1;
  Unix.close fd2

(* unmarshal from a mmap seen as a bigarray *)
let unmarshal fd =
 let a = Bigarray.Array1.map_file fd Bigarray.char Bigarray.c_layout true (-1) in
 let res = Bytearray.unmarshal a 0 in
 Unix.close fd; 
 res


(* marshal to a mmap seen as a bigarray *)

let marshal fd v = 
  let huge_size = 1 lsl 32 in
  let ba = Bigarray.Array1.map_file fd Bigarray.char Bigarray.c_layout true huge_size in
  ignore(Bytearray.marshal_to_buffer ba 0 v [Marshal.Closures]);
  Unix.close fd

(* create a shadow file descriptor *)

let tempfd () =
  let name = Filename.temp_file "mmap" "TMP" in
  try
    let fd = Unix.openfile name [Unix.O_RDWR; Unix.O_CREAT] 0o600 in
    Unix.unlink name;
    fd
  with e -> Unix.unlink name; raise e

(* a simple mapper function that computes 1/nth of the data on each of the n cores in one iteration *)

let simplemapper ncores compute opid al collect =
  (* flush everything *)
  flush_all();
  (* init task parameters *)
  let ln = Array.length al in
  let chunksize = ln/ncores in
  (* create descriptors to mmap *)
  let fdarr=Array.init ncores (fun _ -> tempfd()) in
  (* call the GC before forking *)
  Gc.compact ();
  (* spawn children *)
  for i = 0 to ncores-1 do
    match Unix.fork() with
      0 -> 
	begin
          let lo=i*chunksize in
          let hi=if i=ncores-1 then ln-1 else (i+1)*chunksize-1 in
          let exc_handler e j = (* handle an exception at index j *)
	    info "error at index j=%d in (%d,%d), chunksize=%d of a total of %d got exception %s on core %d \n%!"
	      j lo hi chunksize (hi-lo+1) (Printexc.to_string e) i;
	    exit 1
          in		    
	  let v = compute al lo hi opid exc_handler in
          marshal fdarr.(i) v;
          exit 0
	end
    | -1 -> info "fork error: pid %d; i=%d" (Unix.getpid()) i; 
    | pid -> ()
  done;
  (* wait for all children *)
  for i = 0 to ncores-1 do 
    try ignore(Unix.wait()) 
    with Unix.Unix_error (Unix.ECHILD, _, _) -> ()
  done;
  (* read in all data *)
  let res = ref [] in
  (* iterate in reverse order, to accumulate in the right order *)
  for i = 0 to ncores-1 do
      res:= ((unmarshal fdarr.((ncores-1)-i)):'d)::!res;
  done;
  (* collect all results *)
  collect !res
;;


(* a more sophisticated mapper function, with automatic load balancing *)

(* the type of messages exchanged between master and workers *)

type msg_to_master = Ready of int | Error of int * string;;
type msg_to_worker = Finished | Task of int;;


let setup_children_chans oc pipedown fdarr i = 
  Setcore.setcore i;
  (* send stdout and stderr to a file to avoid mixing output from different cores *)
  reopen_out stdout (Printf.sprintf "stdout.%d" i);
  reopen_out stderr (Printf.sprintf "stderr.%d" i);
  (* close the other ends of the pipe and convert my ends to ic/oc *)
  Unix.close (snd pipedown.(i));
  let pid = Unix.getpid() in
  let ic = Unix.in_channel_of_descr (fst pipedown.(i)) in
  let receive () = Marshal.from_channel ic in
  let signal v = Marshal.to_channel oc v []; flush oc in
  let return v = 
    let d = Unix.gettimeofday() in 
    let _ = marshal fdarr.(i) v in
    debug "worker elapsed %f in marshalling" (Unix.gettimeofday() -. d) in
  let finish () =
    (debug "shutting down (pid=%d)\n%!" pid;
     try close_in ic; close_out oc with _ -> ()
    ); exit 0 in 
  receive, signal, return, finish, pid
;;

(* parametric mapper primitive that captures the parallel structure *)

let mapper ncores ~chunksize compute opid al collect =
  let ln = Array.length al in
  match chunksize with 
    None -> simplemapper ncores compute opid al collect (* no need of load balancing *)
  | Some v when ncores=ln/v -> simplemapper ncores compute opid al collect (* no need of load balancing *)
  | Some v -> 
      (* init task parameters *)
      let chunksize = v and ntasks = ln/v in
      (* flush everything *)
      flush_all ();
      (* create descriptors to mmap *)
      let fdarr=Array.init ncores (fun _ -> tempfd()) in
      (* setup communication channel with the workers *)
      let pipedown=Array.init ncores (fun _ -> Unix.pipe ()) in
      let pipeup_rd,pipeup_wr=Unix.pipe () in
      let oc_up = Unix.out_channel_of_descr pipeup_wr in
      (* call the GC before forking *)
      Gc.compact ();
      (* spawn children *)
      for i = 0 to ncores-1 do
	match Unix.fork() with
	  0 -> 
	    begin    
              let d=Unix.gettimeofday()  in
              (* primitives for communication *)
              Unix.close pipeup_rd;
              let receive,signal,return,finish,pid = setup_children_chans oc_up pipedown fdarr i in
              let reschunk=ref opid in
              let computetask n = (* compute chunk number n *)
		let lo=n*chunksize in
		let hi=if n=ntasks-1 then ln-1 else (n+1)*chunksize-1 in
		let exc_handler e j = (* handle an exception at index j *)
		  begin
		    let errmsg = Printexc.to_string e
		    in info "error at index j=%d in (%d,%d), chunksize=%d of a total of %d got exception %s on core %d \n%!"
		      j lo hi chunksize (hi-lo+1) errmsg i;
		    signal (Error (i,errmsg)); finish()
		  end
		in		    
		reschunk:= compute al lo hi !reschunk exc_handler;
		info "worker on core %d (pid=%d), segment (%d,%d) of data of length %d, chunksize=%d finished in %f seconds"
		  i pid lo hi ln chunksize (Unix.gettimeofday() -. d)
	      in
	      while true do
		(* ask for work until we are finished *)
		signal (Ready i);
		match receive() with
		| Finished -> return (!reschunk:'d); finish ()
		| Task n -> computetask n
	      done;
	    end
	| -1 ->  info "fork error: pid %d; i=%d" (Unix.getpid()) i; 
	| pid -> ()
      done;

      (* close unused ends of the pipes *)
      Array.iter (fun (rfd,_) -> Unix.close rfd) pipedown;
      Unix.close pipeup_wr;

      (* get ic/oc/wfdl *)
      let ocs=Array.init ncores (fun n -> Unix.out_channel_of_descr (snd pipedown.(n))) in
      let ic=Unix.in_channel_of_descr pipeup_rd in

      (* feed workers until all tasks are finished *)
      for i=0 to ntasks-1 do
	match Marshal.from_channel ic with
	  Ready w -> 
	    (debug "sending task %d to worker %d" i w;
	     let oc = ocs.(w) in
	     (Marshal.to_channel oc (Task i) []); flush oc)
	| Error (core,msg) -> (info "aborting due to exception on core %d: %s" core msg; exit 1)
      done;

      (* send termination token to all children *)
      Array.iter (fun oc -> 
	Marshal.to_channel oc Finished []; 
        flush oc; 
        close_out oc
      ) ocs;

      (* wait for all children to terminate *)
      for i = 0 to ncores-1 do 
	try ignore(Unix.wait()) 
	with Unix.Unix_error (Unix.ECHILD, _, _) -> ()
      done;

      (* read in all data *)
      let res = ref [] in
      (* iterate in reverse order, to accumulate in the right order *)
      for i = 0 to ncores-1 do
        res:= ((unmarshal fdarr.((ncores-1)-i)):'d)::!res;
      done;
      (* collect all results *)
      collect !res
;;

(* the parallel mapfold function *)

let parmapfold ?(ncores=1) ?(chunksize) (f:'a -> 'b) (s:'a sequence) (op:'b->'c->'c) (opid:'c) (concat:'c->'c->'c) : 'c=
  (* enforce array to speed up access to the list elements *)
  let al = match s with A al -> al | L l  -> Array.of_list l in
  let compute al lo hi previous exc_handler =
    (* iterate in reverse order, to accumulate in the right order *)
    let r = ref previous in
    for j=0 to (hi-lo) do
      try 
	r := op (f (Array.unsafe_get al (hi-j))) !r;
      with e -> exc_handler e j
    done; !r
  in
  mapper ncores ~chunksize compute opid al  (fun r -> List.fold_right concat r opid)
;;

(* the parallel map function *)

let parmap ?(ncores=1) ?chunksize (f:'a -> 'b) (s:'a sequence) : 'b list=
  (* enforce array to speed up access to the list elements *)
  let al = match s with A al -> al | L l  -> Array.of_list l in
  let compute al lo hi previous exc_handler =
    (* iterate in reverse order, to accumulate in the right order, and add to acc *)
    let f' j = try f (Array.unsafe_get al (lo+j)) with e -> exc_handler e j in
    let rec aux acc = 
      function
	  0 ->  (f' 0)::acc
	| n ->  aux ((f' n)::acc) (n-1)
    in aux previous (hi-lo)
  in
  mapper ncores ~chunksize compute [] al  (fun r -> ExtLib.List.concat r)
;;

(* the parallel fold function *)

let parfold ?(ncores=1) ?chunksize (op:'a -> 'b -> 'b) (s:'a sequence) (opid:'b) (concat:'b->'b->'b) : 'b=
    parmapfold ~ncores ?chunksize (fun x -> x) s op opid concat
;;


(* the parallel map function, on arrays *)

let map_intv lo hi f a =
  let l = hi-lo in
  if l < 0 then [||] else begin
    let r = Array.create (l+1) (f(Array.unsafe_get a lo)) in
    for i = 1 to l do
      Array.unsafe_set r i (f(Array.unsafe_get a (lo+i)))
    done;
    r
  end

let array_parmap ?(ncores=1) ?chunksize (f:'a -> 'b) (al:'a array) : 'b array=
  let compute a lo hi previous exc_handler =
    try 
      Array.concat [(map_intv lo hi f a);previous]
    with e -> exc_handler e lo
  in
  mapper ncores ~chunksize compute [||] al  (fun r -> Array.concat r)
;;


(* This code is highly optimised for operations on float arrays:

   - knowing in advance the size of the result allows to
     pre-allocate it in a shared memory space as a Bigarray;

   - to write in the Bigarray memory area using the unsafe
     functions for Arrays, we trick the OCaml compiler into
     using the Bigarray memory as an Array as follows

       Array.unsafe_get (Obj.magic arr_out) 1

     This works because OCaml compiles access to float arrays
     as unboxed data, without further integrity checks;

   - the final copy into a real OCaml array is done via a memcpy in C.

     This approach gives a performance which is 2 to 3 times higher
     w.r.t. array_parmap, at the price of using Obj.magic and 
     knowledge on the internal representation of arrays and bigarrays.
 *)

exception WrongArraySize

type buf= (float, Bigarray.float64_elt, Bigarray.c_layout) Bigarray.Array1.t * int;; (* should be a long int some day *)

let init_shared_buffer a = 
  let size = Array.length a in
  let fd = tempfd() in
  let arr = Bigarray.Array1.map_file fd Bigarray.float64 Bigarray.c_layout true size in
  
  (* The mmap() function shall add an extra reference to the file associated
     with the file descriptor fildes which is not removed by a subsequent close()
     on that file descriptor.
     http://pubs.opengroup.org/onlinepubs/009695399/functions/mmap.html
   *)
  Unix.close fd; (arr,size)
;;

let array_float_parmap ?(ncores=1) ?chunksize ?result ?sharedbuffer (f:'a -> float) (al:'a array) : float array =
  let size = Array.length al in
  let barr_out = 
    match sharedbuffer with
      Some (arr,s) -> 
	if s<size then 
	  (info "shared buffer is too small to hold the input in array_float_parmap"; raise WrongArraySize)
	else arr
    | None -> fst (init_shared_buffer al)
  in
  (* trick the compiler into accessing the Bigarray memory area as a float array:
     the data in Bigarray is placed at offset 1 w.r.t. a normal array, so we
     get a pointer to that zone into arr_out_as_array, and have it typed as a float
     array *)
  let barr_out_as_array = Array.unsafe_get (Obj.magic barr_out) 1 in
  let compute _ lo hi _ exc_handler =
    try
      for i=lo to hi do 
	Array.unsafe_set barr_out_as_array i (f (Array.unsafe_get al i)) 
      done
    with e -> exc_handler e lo
  in
  mapper ncores ~chunksize compute () al (fun r -> ());
  let res = 
    match result with
      None -> Bytearray.to_floatarray barr_out size
    | Some a -> 
	if Array.length a < size then
	  (info "result array is too small to hold the result in array_float_parmap"; raise WrongArraySize)
        else
	  Bytearray.to_this_floatarray a barr_out size
  in res
;;  

