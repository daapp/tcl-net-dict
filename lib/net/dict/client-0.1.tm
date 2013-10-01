package require Tcl 8.5
package require snit

# Implementation details:
#   Implemented commands:
#     * define
#     * match
#     * show db, show strat, show info, show server
#     * client

# default dict server - dict.org
# default port - 2628
# default encoding - utf-8

# TODO
#   - asyncronous queries to server
#   - check for command size(<1024 bytes)


snit::type net::dict::client {
    typevariable version 0.1

    typevariable errors -array {
	110 {n databases present - text follows}
	111 {n strategies available - text follows}
	112 {database information follows}
	113 {help text follows}
	114 {server information follows}
	130 {challenge follows}
	150 {n definitions retrieved - definitions follow}
	151 {word database name - text follows}
	152 {n matches found - text follows}
	210 {(optional timing and statistical information here)}
	220 {text msg-id}
	221 {Closing Connection}
	230 {Authentication successful}
	250 {ok (optional timing information here)}
	330 {send response}
	420 {Server temporarily unavailable}
	421 {Server shutting down at operator request}
	500 {Syntax error, command not recognized}
	501 {Syntax error, illegal parameters}
	502 {Command not implemented}
	503 {Command parameter not implemented}
	530 {Access denied}
	531 {Access denied, use "SHOW INFO" for server information}
	532 {Access denied, unknown mechanism}
	550 {Invalid database, use "SHOW DB" for list of databases}
	551 {Invalid strategy, use "SHOW STRAT" for a list of strategies}
	552 {No match}
	554 {No databases present}
	555 {No strategies available}
    }

    method errorMessage code {
	if {[info exists errors($code)]} {
	    return $errors($code)
	}
    }

    # read only options
    option -host -readonly yes
    option -port -readonly yes -default 2628
    option -encoding -default "utf-8" -configuremethod SetEncoding
    option -debug -default 0

    # from banner
    variable description ""
    variable capabilities ""

    # todo: authentication
    # variable user
    # variable password

    variable socket ""

    constructor args {
	$self configurelist $args

	if { [catch {set socket [socket $options(-host) $options(-port)]} errorMessage ] } {
	    return -code error $errorMessage
	} else {
	    fconfigure $socket -blocking 1 -buffering line -translation crlf

	    $self configure -encoding $options(-encoding)

	    lassign [$self GetBanner] -> description capabilities
	}
    }

    destructor {
	if {[file channels $socket] ne ""} {
	    $self Request "quit"
	    catch {close $socket}
	}
    }

    ################################



    method Request {command} {
	puts $socket $command
	if {$options(-debug)} {
	    puts stderr "$options(-host):$options(-port) <- $command"
	}
    }

    method GetStatusResponse {} {
	set response [gets $socket]
	if {$options(-debug)} {
	    puts stderr "$options(-host):$options(-port) -> $response"
	}

	# todo: convert to function returning value
	if {[regexp {^(\d{3})\s+(.*)$} $response -> code message]} {
	    return [list $code $message]
	} else {
	    error "invalid status response from dict server: $response"
	}
    }

    method GetTextualResponse {} {
	set result [list]

	while { ! [eof $socket] } {
	    set str [gets $socket]
	    if {$options(-debug)} {
		puts stderr "$options(-host):$options(-port) -> $str"
	    }

	    switch -- $str {
		.       break
		..      {lappend result .}
		default {lappend result $str}
	    }
	}

	return $result
    }

    # read "250 ..." status line
    method GetCommandComplete {} {
	lassign [$self GetStatusResponse] code optionalInfo
	if {$code ne "250"} {
	    error "invalid status code found at the end of definitions: \"250\" expected, but \"$code\" found"
	}
    }

    # return [list code description list_of_capabilities] if code == 220
    # return [list code message] otherwise
    method GetBanner {} {
	lassign [$self GetStatusResponse] code message

	# todo: 420, 421 (see rfc2229)
	if {$code eq "220"} {
	    # _message should contain "text <capabilities> <msg-id>"
	    if { [regexp {(.*) <(.*)> <?(.*)>?} $message -> desc caps _]} {
		return [list $code $desc [split $caps {.}]]
	    } else {
		error "incorrect banner response from server: $message"
	    }
	} else {
	    return [list $code $message]
	}
    }

    method SetEncoding {option encoding} {
	set options($option) $encoding
	if {$socket ne ""} {
	    fconfigure $socket -encoding $encoding
	}
    }

    ### return parts of server response
    method description {} {
	return $description
    }

    method capabilities {} {
	return $capabilities
    }

    ################################

    # methods from RFC2229

    # DEFINE database word
    #
    # arguments
    #	database - name of database, from RFC 2229:
    #		If the database name is specified with an exclamation point
    #		(decimal code 33, "!"), then all of the databases will be
    #		searched until a match is found, and all matches in that
    #		database will be displayed.  If the database name is specified
    #		with a star (decimal code 42, "*"), then all of the matches in
    #		all available databases will be displayed.  In both of these
    #		special cases, the databases will be searched in the same
    #		order as that printed by the "SHOW DB" command.
    #	word - word for search
    # result
    #	list of definitions
    #		{code {definition 1} {definition 2} ... {definition N} }
    #		where `definition' is
    #		{
    #			{word {dictionary name} {dictionary description}}
    #			{definition}
    #		}
    #		or
    #	code and error message
    #		if no definitions was found
    #	error raised
    #		if invalid database was specified
    method define {database word} {
	if { $database == "" } {
	    set database *
	}

	$self Request "define $database $word"
	lassign [$self GetStatusResponse] code message

	if {$code eq "150"} {
	    # 150 n definitions retrieved - definitions follows
	    set nwords [lindex $message 0]
	    set status {}
	    set words {}

	    for {set i 0} {$i < $nwords} {incr i} {
		gets $socket str
		set status [lassign $str statusCode]
		if {$statusCode eq "151"} {
		    lappend words $status [join [$self GetTextualResponse] \n]
		} else {
		    error "invalid status code \"$statusCode\": 151 is expected"
		}
	    }
	    $self GetCommandComplete

	    return [list $code $words]
	} else {
	    return [list $code $message]
	}
    }

    # SHOW command ?args?
    #
    # arguments
    #	db
    #	databases
    #		Return the list of currently accessible databases {code {database
    #		1} {description 1} {database 2} {description 2} ... {database
    #		N} {description N} } or empty list if no databases present
    #
    #	strat
    #	strategies
    #		Return the list of currently supported search strategies {code
    #		{strategy 1} {description 1} {strategy 2} {description 2} ...
    #		{strategy N} {description N} } or empty list {} if
    #		no strategies present
    #
    #	info databaseName
    #		Return the source, copyright, and licensing information about
    #		the specified databaseName or empty string if invalid database
    #		was specified
    #
    #	server
    #		Return local server information written by the local
    #		administrator. This could include information about local
    #		databases or strategies, or administrative information such as
    #		who to contact for access to databases requiring
    #		authentication.
    #

    method show {what args} {
	switch -- $what {
	    db -
	    databases {
		return [$self ShowDatabases]
	    }
	    strat -
	    strategies {
		return [$self ShowStrategies]
	    }
	    info {
		return [$self ShowInfo $args]
	    }
	    server {
		return [$self ShowServer]
	    }
	    default {
		error "unknown command \"show $what\": should be one of db, databases, strat, strategies, info or server"
	    }
	}
    }

    method ShowDatabases {} {
	$self Request "show databases"
	lassign [$self GetStatusResponse] code message

	if {$code eq "110"} {
	    # 110 n databases present - text follows
	    # n - number of databases
	    set databases [$self GetTextualResponse]
	    $self GetCommandComplete

	    return [list $code $databases]

	} else {
	    return [list $code $message]
	}
    }

    method ShowStrategies {} {
	$self Request "show strategies"
	lassign [$self GetStatusResponse] code message

	if {$code eq "111"} {
	    # 111 n strategies available - text follows
	    # n - number of databases
	    set strategies [$self GetTextualResponse]
	    $self GetCommandComplete
	    return [list $code $strategies]
	} else {
	    return [list $code $message]
	}
    }

    method ShowInfo {database} {
	$self Request "show info $database"
	lassign [$self GetStatusResponse] code message

	if {$code eq "112"} {
	    # 112 database information follows
	    set info [$self GetTextualResponse]
	    $self GetCommandComplete

	    return [list $code $info]
	} else {
	    return [list $code $message]
	}
    }

    method ShowServer {} {
	$self Request "show server"
	lassign [$self GetStatusResponse] code message

	if {$code eq "114"} {
	    # 114 database information follows
	    set server [$self GetTextualResponse]
	    $self GetCommandComplete
	    return [list $code $server]
	} else {
	    return [list $code $message]
	}
    }

    # MATCH database strategy word
    #
    # arguments
    #	database - name of database, from RFC 2229:
    #	  If the database name is specified with an exclamation point (decimal
    #	  code 33, "!"), then all of the databases will be searched until a
    #	  match is found, and all matches in that database will be displayed.
    #	  If the database name is specified with a star (decimal code 42, "*"),
    #	  then all of the matches in all available databases will be displayed.
    #	  In both of these special cases, the databases will be searched in the
    #	  same order as that printed by the "SHOW DB"
    #	  command.
    #   strategy
    #	  If the strategy is specified using a period (decimal code 46, "."),
    #	  then the word will be matched using a server-dependent default
    #	  strategy, which should be the best strategy available for interactive
    #	  spell checking.  This is usually a derivative of the Levenshtein
    #	  algorithm.

    method match {database strategy word} {
	$self Request "match $database $strategy $word"
	lassign [$self GetStatusResponse] code message

	if {$code eq "152"} {
	    # 152 n matches found - text follows
	    # todo: read n matches and return as list
	    set matches [$self GetTextualResponse]
	    $self GetCommandComplete

	    return [list $code $matches]
	} else {
	    return [list $code $message]
	}
    }

    # CLIENT text
    #
    # arguments
    #   text - identification of client

    method client {text} {
	$self Request "client $text"

	# 250 ok (optional timing information here)
	# return optional timing information
	return [$self GetStatusResponse]
    }
}

package provide net::dict::client $net::dict::client::version
