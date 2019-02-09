(* derived from ISC-licensed mirage-tcpip/lib_test/test_arp.ml *)

let count2 = ref 0

module Test (R : Mirage_random.C) = struct
let hdr buf =
  Cstruct.BE.set_uint16 buf 0 1 ;
  Cstruct.BE.set_uint16 buf 2 0x0800 ;
  Cstruct.set_uint8 buf 4 6 ;
  Cstruct.set_uint8 buf 5 4

let gen_int () =
  let buf = R.generate 1 in
  Cstruct.get_uint8 buf 0

let gen_op buf off =
  let op = gen_int () in
  let op = 1 + op mod 2 in
  Cstruct.BE.set_uint16 buf off op

let gen_arp buf =
  hdr buf ;
  gen_op buf 6 ;
  let addresses = R.generate 20 in
  Cstruct.blit addresses 0 buf 8 20 ;
  28

let gen_req buf =
  hdr buf ;
  Cstruct.BE.set_uint16 buf 6 1 ;
  let addresses = R.generate 20 in
  Cstruct.blit addresses 0 buf 8 20 ;
  28

let gen_ip () =
  let last = R.generate 1 in
  let ip = "\010\000\000" ^ (Cstruct.to_string last) in
  Ipaddr.V4.of_bytes_exn ip

let ip = Ipaddr.V4.of_string_exn "10.0.0.0"
let mac = Macaddr.of_string_exn "00:de:ad:be:ef:00"

let gen_rep buf =
  hdr buf ;
  Cstruct.BE.set_uint16 buf 6 2 ;
  let omac = R.generate 6 in
  Cstruct.blit omac 0 buf 8 6 ;
  let oip = gen_ip () in
  Cstruct.blit_from_string (Ipaddr.V4.to_bytes oip) 0 buf 14 4 ;
  Cstruct.blit_from_string (Macaddr.to_bytes mac) 0 buf 18 6 ;
  Cstruct.blit_from_string (Ipaddr.V4.to_bytes ip) 0 buf 24 4 ;
  28

let other_ip = Ipaddr.V4.of_string_exn "10.0.0.1"
let other_mac = Macaddr.of_string_exn "00:de:ad:be:ef:01"

let myreq buf =
  hdr buf ;
  Cstruct.BE.set_uint16 buf 6 1 ;
  Cstruct.blit_from_string (Macaddr.to_bytes other_mac) 0 buf 8 6 ;
  Cstruct.blit_from_string (Ipaddr.V4.to_bytes other_ip) 0 buf 14 4 ;
  Cstruct.blit_from_string (Macaddr.to_bytes mac) 0 buf 18 6 ;
  Cstruct.blit_from_string (Ipaddr.V4.to_bytes ip) 0 buf 24 4 ;
  28

open Lwt.Infix

module B = Basic_backend.Make
module V = Vnetif.Make(B)
module E = Ethernet.Make(V)
module A = Arp.Make(E)(OS.Time)

let c = ref 0
let gen arp buf =
  c := !c mod 100 ;
  match !c with
  | x when x >= 00 && x < 10 ->
    let len = gen_int () mod 28 in
    let r = R.generate len in
    Cstruct.blit r 0 buf 0 len ;
    len
  | x when x >= 10 && x < 20 -> gen_req buf
  | x when x >= 20 && x < 50 -> myreq buf
  | x when x >= 50 && x < 80 ->
    if x mod 2 = 0 then
      (let rand = gen_int () in
       for _i = 0 to rand do
         let ip = gen_ip () in
         Lwt.async (fun () -> A.query arp ip)
       done) ;
    gen_rep buf
  | x when x >= 80 && x < 100 -> gen_arp buf
  | _ -> invalid_arg "bla"

let rec query arp () =
  incr count2 ;
  let ip = gen_ip () in
  Lwt.async (fun () -> A.query arp ip) ;
  OS.Time.sleep_ns (Duration.of_us 100) >>= fun () ->
  query arp ()

type arp_stack = {
  backend : B.t;
  netif: V.t;
  ethif: E.t;
  arp: A.t;
}

let get_arp ?(backend = B.create ~use_async_readers:true
                ~yield:(fun() -> Lwt_main.yield ()) ()) () =
  V.connect backend >>= fun netif ->
  E.connect netif >>= fun ethif ->
  A.connect ethif >>= fun arp ->
  Lwt.return { backend; netif; ethif; arp }

let rec send netif gen () =
  V.write netif ~size:Arp_packet.size gen >>= function
  | Ok _ -> send netif gen ()
  | Error _ -> Lwt.return_unit

let runit () =
  Printf.printf "starting\n%!";
  get_arp () >>= fun stack ->
  get_arp ~backend:stack.backend () >>= fun other ->
  A.set_ips stack.arp [ip] >>= fun () ->
  let count = ref 0 in
  Lwt.pick [
    (V.listen stack.netif (fun b -> incr count ; A.input stack.arp b) >|= fun _ -> ());
    send other.netif (fun b ->
        let res = R.generate 28 in
        Cstruct.blit res 0 b 0 28 ;
        28) () ;
    OS.Time.sleep_ns (Duration.of_sec 5)
  ] >>= fun () ->
  Printf.printf "%d random input\n%!" !count ;
  count := 0 ;
  Lwt.pick [
    (V.listen stack.netif (fun b -> incr count ; A.input stack.arp b) >|= fun _ -> ());
    send other.netif gen_arp () ;
    OS.Time.sleep_ns (Duration.of_sec 5)
  ] >>= fun () ->
  Printf.printf "%d random ARP input\n%!" !count ;
  count := 0 ;
  Lwt.pick [
    (V.listen stack.netif (fun b -> incr count ; A.input stack.arp b) >|= fun _ -> ());
    send other.netif gen_req () ;
    OS.Time.sleep_ns (Duration.of_sec 5)
  ] >>= fun () ->
  Printf.printf "%d requests\n%!" !count ;
  count := 0 ;
  Lwt.pick [
    (V.listen stack.netif (fun b -> incr count ; A.input stack.arp b) >|= fun _ -> ());
    send other.netif gen_rep () ;
    OS.Time.sleep_ns (Duration.of_sec 5)
  ] >>= fun () ->
  Printf.printf "%d replies\n%!" !count ;
  count := 0 ;
  Lwt.pick [
    (V.listen stack.netif (fun b -> incr count ; A.input stack.arp b) >|= fun _ -> ());
    send other.netif (gen stack.arp) () ;
    OS.Time.sleep_ns (Duration.of_sec 5)
  ] >>= fun () ->
  Printf.printf "%d mixed\n%!" !count ;
  count := 0 ;
  Lwt.pick [
    (V.listen stack.netif (fun b -> incr count ; A.input stack.arp b) >|= fun _ -> ());
    send other.netif gen_rep  () ;
    query stack.arp () ;
    OS.Time.sleep_ns (Duration.of_sec 5)
  ] >|= fun () ->
  Printf.printf "%d queries (%d qs)\n%!" !count !count2
end

module T = Test(Mirage_random_test)
let () =
  Mirage_random_test.initialize () ;
  Lwt_main.run (T.runit ()) ;
  count2 := 0 ;
  Lwt_main.run (T.runit ()) ;
  count2 := 0 ;
  Lwt_main.run (T.runit ())
