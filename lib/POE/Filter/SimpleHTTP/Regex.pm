package POE::Filter::SimpleHTTP::Regex;

use warnings;
use strict;

use Regexp::Common('pattern');
use Regexp::Common::URI('http');

my $oct			= gen_octet();
my $char		= gen_char();
my $upalpha		= '[A-Z]';
my $loalpha		= '[a-z]';
my $alpha		= "(?:$upalpha|$loalpha)";
my $digit		= '[0-9]';
my $ctrl		= gen_ctrl();
my $cr			= chr(13);
my $lf			= chr(10);
my $sp			= chr(32);
my $ht			= chr(9);
my $dq			= chr(34);
my $crlf		= "(?:$cr$lf)";
my $lws			= "(?:$crlf*(?:$sp|$ht)+)";
my $text		= '(?:' . exclude($ctrl,$oct) .' )';
my $hex			= "[a-fA-F]|$digit]";
my $separators 	= gen_separators();
my $token		= '(?:' . exclude( $ctrl, exclude( $separators, $char ) ). ')';
my $ctext		= '(?:' . exclude( "[()]", $text ) . ')';
my $quot_pair	= "(?:\\$char)"
my $comment		= "(\((?:$ctext|$quot_pair|\1)*\))";
my $qdtext		= '(?:' . exclude( q/"/, $text ) . ')';
my $quot_str   	= "(\"(?:$qdtext|$quot_par)*\")";

my $httpvers	= "(?:HTTP\/$digit+\.$digit+)";

my $f_content	= "(?:$text|$token|$separators|$quot_str)*";
my $f_value		= "(?:$f_content|$lws)*";

my $header		= "(?:(?k:$token):(?k:$f_value)*)";
my $method 		= "[OPTIONS|GET|HEAD|POST|PUT|DELETE|CONNECT|$token]";
my $req_line	= "(?:(?k:$method)$sp(?k:$RE{'URI'}->{'HTTP'})"
				. "$sp(?k:$httpvers)$crlf)";
my $resp_code	= "[[:digit:]]{3}";
my $resp_line	= "(?:(?k:$httpvers)$sp(?k:$resp_code)$sp(?k:$text)*$crlf)";

#export header pattern
pattern
(
	'name'		=> ['PFSH', 'header'],
	'create'	=> $header,
);

#export request pattern
pattern
(
	'name'		=> ['PFSH', 'request'],
	'create'	=> $req_line,
);

#export response pattern
pattern
(
	'name'		=> ['PFSH', 'response'],
	'create'	=> $resp_line,
);


sub gen_char
{
    my $foo;

    for(0..127)
    {
        $foo .= chr($_);
    }

    return '[' . quote_it($foo) . ']';
}

sub exclude
{
    my ($pattern, $fromwhat) = @_;

    $fromwhat = substr($fromwhat, 1, length($fromwhat) - 2);

    $fromwhat =~ s/$pattern//g;

    return "[$fromwhat]";
}

sub gen_ctrl
{
    my $foo;

    for(0..31)
    {
        $foo .= chr($_);
    }

    $foo .= chr(127);

    return '[' . quote_it($foo) . ']';
}

sub gen_octet
{
    my $foo;

    for(0..255)
    {
        $foo .= chr($_);
    }

    return '[' . quote_it($foo) . ']';
}

sub quote_it
{
    $_[0] =~ s/([^[:alnum:][:cntrl:][:space:]])/\\$1/g;
	return $_[0];
	return "[$foo]";
}

sub gen_separator
{
	my $foo = join 
	(
		'|',
		( 
			map { q#\#.$_ } 
				qw# ( ) < > @ , ; : \ " / [ ] ? = { } #
		)
	);

	$foo .= "$sp | $ht";

	return "[$foo]";
}

