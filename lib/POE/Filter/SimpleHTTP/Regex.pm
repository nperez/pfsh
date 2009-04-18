package POE::Filter::SimpleHTTP::Regex;

use warnings;
use strict;

use bytes;
use Regexp::Common('URI');

sub quote_it
{
    $_[0] =~ s/([^[:alnum:][:cntrl:][:space:]])/\\$1/g;
	
	if($_[0] =~ /-/)
	{
		$_[0] =~ s/-//g;
		$_[0] .= '-';
	}

	return $_[0];
}

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

sub gen_separators
{
	my $foo = join 
	(
		'|',
		( 
			map { chr(92).$_ } 
			(
				split
				(
					/\s/,
				 	'( ) < > @ , ; : \ " / [ ] ? = { }'
				)
			)
		)
	);

	$foo .= chr(32) . ' | ' . chr(9);

	return "$foo";
}

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
my $text		= exclude($ctrl,$oct);
my $hex			= "[a-fA-F]|$digit]";
my $separators 	= gen_separators();
my $token		= exclude( $ctrl, exclude( $separators, $char ) );
my $ctext		= exclude( "[()]", $text );
my $quot_pair	= "\\$char";
my $comment		= "(?:\((?:$ctext|$quot_pair|\1)*\))";
my $qdtext		= exclude( q/"/, $text );
my $quot_str   	= "(?:\"(?:$qdtext|$quot_pair)*\")";

my $httpvers	= "HTTP\/$digit+\.$digit+";

my $f_content	= "$text|$token|$separators|$quot_str";
my $f_value		= "(?:(?:$f_content+)|$lws)";

my $header		= "($token+):($f_value*)";
my $method 		= "OPTIONS|GET|HEAD|POST|PUT|DELETE|CONNECT|$token";
my $req_line	= "($method)$sp($RE{'URI'}->{'HTTP'})"
				. "$sp($httpvers)$crlf*";
my $resp_code	= $digit . '{3}';
my $resp_line	= "($httpvers)$sp($resp_code)$sp($text)*$crlf*";

our $RESPONSE = qr/$resp_line/;
our $REQUEST = qr/$req_line/;
our $HEADER = qr/$header/;

my $HTTP = 'HTTP/1.1';
my $CODE = '200';
my $MESSAGE = 'OK';

if($HTTP =~ /(?:$httpvers)/)
{
	warn 'PASSED HTTP';
}

if($CODE =~ /(?:$resp_code)/)
{
	warn 'PASSED RESPONSE CODE';
}

if($MESSAGE =~ /(?:$text)/)
{
	warn 'PASSED MESSAGE TEXT';
}

my $COMBINED = "$HTTP $CODE $MESSAGE\x0D\x0A";

if($COMBINED =~ /(?:$httpvers)$sp(?:$resp_code)$sp(?:$text)*$crlf/)
{
	warn 'PASSED RESPONSE LINE';
}

my $HEADER = "Server: Apache/1.3.37 (Unix) mod_perl/1.29";

if($HEADER =~ /(?:$token):(?:$f_value)*/)
{
	warn 'PASSED HEADER 1 ';
}

my $HEAD2 = "Date: Sun, 05 Aug 2007 18:46:50 GMT";

if($HEAD2 =~ $POE::Filter::SimpleHTTP::Regex::HEADER)
{
	warn $1;
	warn $2;
}
#$string =~ s/[[:cntrl:]]//g;
#$string =~ s/(?<!\\)(\()(?!\?:)/\n$1\n/g;
#$string =~ s/(?<!\\)(\()(?=\?:)/\n\t$1/g;
#$string =~ s/(?<!\\)(\))/\n$1\n/g;
#$string =~ s/$crlf//g;
#$string =~ s/$lws//g;
#warn $string;

1;
