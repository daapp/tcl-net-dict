#! /bin/sh
# \
exec tclsh "$0" ${1+"$@"}

tcl::tm::path add lib
package require net::dict::client

net::dict::client localdict -host localhost -debug 0

lassign [localdict show server] code server
puts "server: $code\n[join $server \n]\n"

lassign [localdict show databases] code databases
puts "databases: $code\n[join $databases \n]\n"

lassign [localdict show strategies] code strategies
puts "strategies: $code\n[join $strategies \n]\n"

lassign [localdict show info mueller7accent] code info
puts "info: $code\n[join $info \n]\n"

lassign [localdict define {} hello] code defHello
puts "hello: $code\n[join $defHello \n]\n"

lassign [localdict match mueller7accent prefix hel] code matches
puts "match hel: $code\n[join $matches \n]\n"
