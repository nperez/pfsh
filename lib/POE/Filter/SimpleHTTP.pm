package POE::Filter::SimpleHTTP;
use Moose;
extends('POE::Filter', 'Moose::Object');

use Moose::Util::TypeConstraints;

use Data::Dumper;
use HTTP::Status;
use HTTP::Response;
use HTTP::Request;
use URI;
use Compress::Zlib;
use Regexp::Common;

use POE::Filter::SimpleHTTP::Regex;
use POE::Filter::SimpleHTTP::Error;

use bytes;

our $VERSION = '0.01';
our $DEBUG = 0;

use constant
{
    PARSE_START         => 0,
    PREAMBLE_COMPLETE   => 1,
    HEADER_COMPLETE     => 2,
    CONTENT_COMPLETE    => 3,
    CLIENT_MODE         => 0,
    SERVER_MODE         => 1,
};

subtype 'ParseState'
    => as 'Int'
    => where { -1 < $_  && $_ < 4 }
    => message { 'Incorrect ParseState' };

subtype 'FilterMode'
    => as 'Int'
    => where { $_ == 0 || $_ == 0 }
    => message { 'Incorrect FilterMode' };

subtype 'Uri'
    => as 'Object'
    => where { $_->isa('URI') };

coerce 'Uri'
    => from 'Object'
        => via { $_->isa('URI') 
            ? $_ 
            : Params::Coerce::coerce( 'URI', $_ ) }
    => from 'Str'
        => via { URI->new( $_, 'http' ) };

has raw => 
(
    is => 'rw', 
    isa => 'ArrayRef[Str]', 
    default => sub {[]},
    clearer => 'clear_raw',
    lazy => 1
);

has preamble => 
( 
    is => 'rw', 
    isa => 'ArrayRef[Str]', 
    default => sub {[]},
    clearer => 'clear_preamble',
    lazy => 1
);

has header => 
( 
    is => 'rw', 
    isa => 'ArrayRef[Str]', 
    default => sub {[]},
    clearer => 'clear_header',
    lazy => 1
);

has content => 
( 
    is => 'rw', 
    isa => 'ArrayRef[Str]', 
    default => sub {[]},
    clearer => 'clear_content',
    lazy => 1
);

has state => 
( 
    is => 'rw', 
    isa => 'ParseState',
    default => 0,
    clearer => 'clear_state',
    lazy => 1
);

has mode => 
( 
    is => 'rw', 
    isa => 'FilterMode',
    default => 0,
    lazy => 1
);

has uri => 
( 
    is => 'rw', 
    isa => 'Uri', 
    default => '/',
    lazy => 1
);

has useragent => 
( 
    is => 'rw', 
    isa => 'Str', 
    default => __PACKAGE__ . '/' . $VERSION,
    lazy => 1
);

has host => 
( 
    is => 'rw', 
    isa => 'Str', 
    default => 'localhost',
    lazy => 1
);

has server => 
( 
    is => 'rw', 
    isa => 'Str', 
    default => __PACKAGE__ . '/' . $VERSION,
    lazy => 1
);

has mimetype =>
(
    is => 'rw',
    isa => 'Str',
    default => 'text/plain',
    lazy => 1
);

sub new 
{
    my $class = shift(@_);

    return $class->meta->new_object
    (
        __INSTANCE__ => bless({}, $class),
        @_,
    );
}


sub reset()
{
	my ($self) = @_;
    $self->clear_raw();
    $self->clear_preamble();
    $self->clear_header();
    $self->clear_content();
    $self->clear_state();
}

override 'get_one' => 
sub
{
	my ($self) = @_;
	
	my $buffer = '';

	while(defined(my $raw = shift(@{$self->raw()})) || length($buffer))
	{
		$buffer .= $raw if defined($raw);
        my $state = $self->state();

		if($state < +PREAMBLE_COMPLETE)
		{
			if($buffer =~ /^\x0D\x0A/)
			{
				# skip the blank lines at the beginning if we have them
				substr($buffer, 0, 2, '');
				next;
			
			} else {
				
				if($buffer =~ $POE::Filter::SimpleHTTP::Regex::REQUEST
			        or $buffer =~ $POE::Filter::SimpleHTTP::Regex::RESPONSE)
				{
                    push(@{$self->preamble()}, $self->get_chunk(\$buffer));
                    $self->state(+PREAMBLE_COMPLETE);

				} else {
					
					return 
                    [
                        POE::Filter::SimpleHTTP::Error->new
                        (
                            +UNPARSABLE_PREAMBLE,
                            $buffer
                        )
                    ];

				}
			}

		} elsif($state < +HEADER_COMPLETE) {
			
			if($buffer =~ /^\x0D\x0A/)
			{
				substr($buffer, 0, 2, '');
				$self->state(+HEADER_COMPLETE);
			
			} else {
				
				#gather all of the headers from this chunk
				while($buffer =~ $POE::Filter::SimpleHTTP::Regex::HEADER 
					and $buffer !~ /^\x0D\x0A/)
				{
					push(@{$self->header()}, $self->get_chunk(\$buffer));
				}

			}

		} elsif($state < +CONTENT_COMPLETE) {
			
			if($buffer =~ /^\x0D\x0A/)
			{
				substr($buffer, 0, 2, '');
				$self->state(+CONTENT_COMPLETE);

			} else {
				
				if(index($buffer, "\x0D\x0A") == -1)
				{
					push(@{$self->content}, $buffer);
				
				} else {

					push(@{$self->content}, $self->get_chunk(\$buffer));
				}

			}

		} else {
		    
            return
            [
                POE::Filter::SimpleHTTP::Error->new
                (
                    +TRAILING_DATA,
                    $buffer
                )
            ];
		}
	}
		
	if($self->state() == +CONTENT_COMPLETE)
	{
		return [$self->build_message()];
	}
	else
	{
		warn Dumper($self) if $DEBUG;
		return [];
	}
};

override 'get_one_start' =>
sub
{
	my ($self, $data) = @_;
	
	if(!ref($data))
	{
		$data = [$data];
	}

	push(@{$self->raw()}, @$data);
	
};

override 'put' =>
sub
{
	my ($self, $content) = @_;
	
	my $http;

	if($self->mode() == +SERVER_MODE)
	{
		my $response;
		
        $response = HTTP::Response->new(+RC_OK);
        $response->content_type($self->mimetype());
        $response->server($self->server());
        
        $response->add_content($_) for @$content;

		$http = $response;

	} else {

		my $request = HTTP::Request->new();

        $request->method('POST');
        $request->uri($self->uri());
        $request->user_agent($self->useragent()); 
        
		$request->add_content($_) for @$content;
		
		$http = $request;
	}

	$http->protocol('HTTP/1.0');
	
	return [$http];
};


sub get_chunk()
{
	my ($self, $buffer) = @_;

	#find the break
	my $break = index($$buffer, "\x0D\x0A");
	
	my $match;

	if($break < 0)
	{
		#pullout the whole string
		$match = substr($$buffer, 0, length($$buffer), '');
	
	} elsif($break > -1) {
		
		#pull out string until newline
		$match = substr($$buffer, 0, $break, '');
		
		#remove the CRLF from the buffer
		substr($$buffer, 0, 2, '');
	}

	return $match;
}

sub build_message()
{
	my ($self) = @_;
	
	my $message;

	my $preamble = shift(@{$self->preamble()});

	if($preamble =~ $POE::Filter::SimpleHTTP::Regex::REQUEST)
	{
		my ($method, $uri) = ($1, $2);

		$message = HTTP::Request->new($method, $uri);
	
	} elsif($preamble =~ $POE::Filter::SimpleHTTP::Regex::RESPONSE) {
	
		my ($code, $text) = ($2, $3);

		$message = HTTP::Response->new($code, $text);
	}


	foreach my $line (@{$self->header()})
	{
		if($line =~ $POE::Filter::SimpleHTTP::Regex::HEADER)
		{
			$message->header($1, $2);
		}
	}

	warn Dumper($message) if $DEBUG;
	
	# If we have a transfer encoding, we need to decode it 
	# (ie. unchunkify, decompress, etc)
	if($message->header('Transfer-Encoding'))
	{
		warn 'INSIDE TE' if $DEBUG;
		my $te_raw = $message->header('Transfer-Encoding');
		my $te_s = 
		[ 
			(
				map 
				{ 
					my ($token) = split(/;/, $_); $token; 
				} 
				(reverse(split(/,/, $te_raw)))
			)
		];
		
		my $buffer = '';
		my $subbuff = '';
		my $size = 0;

		while( my $content_line = shift(@{$self->content()}) )
		{
			# Start of a new chunk
			if($size == 0 and length($subbuff) == 0)
			{
				if($content_line =~ /^([\dA-Fa-f]+)(?:\x0D\x0A)*/)
				{
					warn $1;
					$size = hex($1);
				}
				
				# If we got a zero size, it means time to process trailing 
				# headers if enabled
				if($size == 0)
				{
					if($message->header('Trailer'))
					{
						while( my $tline = shift(@{$self->content()}) )
						{
							if($tline =~ $POE::Filter::SimpleHTTP::Regex::HEADER)
							{
								my ($key, $value) = ($1, $2);
								$message->header($key, $value);
							}
						}
					}
					$self->reset();
					return $message;
				}
			}
			
			while($size > 0)
			{
				warn $size;
				my $subline = shift(@{$self->content()});
				
				while(length($subline))
				{
					my $buff = substr($subline, 0, 4096, '');
					$size -= length($buff);
					$subbuff .= $buff;
				}
			}

			$buffer .= $subbuff;

			$subbuff = '';
		}
		
		my $chunk = shift(@$te_s);
		if($chunk !~ /chunked/)
		{
			warn 'CHUNKED ISNT LAST' if $DEBUG;
            
            return POE::Filter::SimpleHTTP::Error->new
            (
                +CHUNKED_ISNT_LAST,
                join(' ',($chunk, @$te_s))
            );
		}

		foreach my $te (@$te_s)
		{
			if($te =~ /deflate/)
			{
				my ($inflate, $status) = Compress::Zlib::inflateInit();
				if(!defined($inflate))
				{
					warn 'INFLATE FAILED TO INIT' if $DEBUG;
                    return POE::Filter::SimpleHTTP::Error->new
                    (
                        +INFLATE_FAILED_INIT,
                        $status
                    );
				}
				else
				{
					my ($buffer, $status) = $inflate->(\$buffer);
					if($status != +Z_OK or $status != +Z_STREAM_END)
					{
						warn 'INFLATE FAILED TO DECOMPRESS' if $DEBUG;
						return POE::Filter::SimpleHTTP::Error->new
                        (
                            +INFLATE_FAILED_INFLATE,
                            $status
                        );
					}
				}
			
			} elsif($te =~ /compress/) {

				$buffer = Compress::Zlib::uncompress(\$buffer);
				if(!defined($buffer))
				{
					warn 'UNCOMPRESS FAILED' if $DEBUG;
					return POE::Filter::SimpleHTTP::Error->new
                    (
                        +UNCOMPRESS_FAILED
                    );
				}

			} elsif($te =~ /gzip/) {

				$buffer = Complress::Zlib::memGunzip(\$buffer);
				if(!defined($buffer))
				{
					warn 'GUNZIP FAILED' if $DEBUG;
					return POE::Filter::SimpleHTTP::Error->new
                    (
                        +GUNZIP_FAILED
                    );
				}
			
			} else {
                
                warn 'UNKNOWN TRANSFER ENCOODING' if $DEBUG;
                return POE::Filter::SimpleHTTP::Error->new
                (
                    +UNKNOWN_TRANSFER_ENCODING,
                    $te
                );
			}
		}

		$message->content_ref(\$buffer);
	
	} else {

		$message->add_content($_) for @{$self->content()};
	}

	# We have the type, the headers, and the content. Return the object
	return $message;
}

=head1 AUTHOR

Nicholas R. Perez, C<< <nicholasrperez at gmail.com> >>

=head1 BUGS

Please report any bugs or feature requests to
C<bug-poe-filter-simplehttp at rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=POE-Filter-SimpleHTTP>.
I will be notified, and then you'll automatically be notified of progress on
your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc POE::Filter::SimpleHTTP

You can also look for information at:

=over 4

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/POE-Filter-SimpleHTTP>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/POE-Filter-SimpleHTTP>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=POE-Filter-SimpleHTTP>

=item * Search CPAN

L<http://search.cpan.org/dist/POE-Filter-SimpleHTTP>

=back

=head1 ACKNOWLEDGEMENTS

=head1 COPYRIGHT & LICENSE

Copyright 2007 Nicholas R. Perez, all rights reserved.

This program is released under the following license: gpl

=cut

1; # End of POE::Filter::SimpleHTTP
