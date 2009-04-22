package POE::Filter::SimpleHTTP;
use 5.010;
use Moose;
extends('POE::Filter', 'Moose::Object');

use Moose::Util::TypeConstraints;

use Data::Dumper;
use HTTP::Status;
use HTTP::Response;
use HTTP::Request;
use URI;
use Compress::Zlib;

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

sub get_one()
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
            }
				
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
                        {
                            error => +UNPARSABLE_PREAMBLE,
                            context => $buffer
                        }
                    )
                ];
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
            
            if($buffer =~ /^\x0D\x0A$/)
            {
                # skip the blank lines at the end if we have them
                substr($buffer, 0, 2, '');
                next;
            }

            return
            [
                POE::Filter::SimpleHTTP::Error->new
                (
                    {
                        error => +TRAILING_DATA,
                        context => $buffer
                    }
                )
            ];
		}
	}
		
	if($self->state() == +CONTENT_COMPLETE)
	{
		my $ret = [$self->build_message()];
        $self->reset();
        return $ret;
	}
	else
	{
		warn Dumper($self) if $DEBUG;
		return [];
	}
};

sub get_one_start()
{
	my ($self, $data) = @_;
	
	if(!ref($data))
	{
		$data = [$data];
	}

	push(@{$self->raw()}, @$data);
	
};

sub put()
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
        my $content = '';
$DB::single=1;
		while(defined(my $content_line = shift(@{$self->content()})) )
		{
			# Start of a new chunk
			if($size == 0)
			{
				if($content_line =~ /^([\dA-Fa-f]+)(?:\x0D\x0A)*/)
				{
					warn "CHUNK SIZE IN HEX: $1" if $DEBUG;
					$size = hex($1);
				}
				
				# If we got a zero size, it means time to process trailing 
				# headers if enabled
				if($size == 0)
				{
                    warn "SIZE ZERO HIT" if $DEBUG;
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
					return $message;
				}
			}
			
			while($size > 0)
			{
				warn "SIZE: $size" if $DEBUG;
				my $subline = shift(@{$self->content()});
				while(length($subline))
				{
                    warn 'LENGTH OF SUBLINE: ' . length($subline) if $DEBUG;
					my $buff = substr($subline, 0, 4069, '');
					$size -= length($buff);
					$subbuff .= $buff;
				}
			}

			$buffer .= $subbuff;
            warn 'BUFFER LENGTH: ' .length($buffer) if $DEBUG;

			$subbuff = '';
		}
		
		my $chunk = shift(@$te_s);
		if($chunk !~ /chunked/)
		{
			warn 'CHUNKED ISNT LAST' if $DEBUG;
            
            return POE::Filter::SimpleHTTP::Error->new
            (
                {
                    error => +CHUNKED_ISNT_LAST,
                    context => join(' ',($chunk, @$te_s))
                }
            );
		}
        
        if(!scalar(@$te_s))
        {
            $content = $buffer;
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
                        {
                            error => +INFLATE_FAILED_INIT,
                            context => $status
                        }
                    );
				}
				else
				{
                    warn 'BUFFER LENGTH BEFORE INFLATE: '. length($buffer) if $DEBUG;
					my ($content, $status) = $inflate->inflate(\$buffer);
                    warn "DECOMPRESSED CONTENT: $content" if $DEBUG && $content;
					if($status != +Z_OK or $status != +Z_STREAM_END)
					{
						warn 'INFLATE FAILED TO DECOMPRESS' if $DEBUG;
						return POE::Filter::SimpleHTTP::Error->new
                        (
                            {
                                error => +INFLATE_FAILED_INFLATE,
                                context => $status
                            }
                        );
					}
				}
			
			} elsif($te =~ /compress/) {

				$content = Compress::Zlib::uncompress(\$buffer);
				if(!defined($content))
				{
					warn 'UNCOMPRESS FAILED' if $DEBUG;
					return POE::Filter::SimpleHTTP::Error->new
                    (
                        {
                            error => +UNCOMPRESS_FAILED
                        }
                    );
				}

			} elsif($te =~ /gzip/) {

                warn 'BUFFER LENGTH BEFORE GUNZIP: '. length($buffer) if $DEBUG;
				$content = Compress::Zlib::memGunzip(\$buffer);
                warn "DECOMPRESSED CONTENT: $content" if $DEBUG;
				if(!defined($content))
				{
					warn 'GUNZIP FAILED' if $DEBUG;
					return POE::Filter::SimpleHTTP::Error->new
                    (
                        {
                            error => +GUNZIP_FAILED
                        }
                    );
				}
			
			} else {
                
                warn 'UNKNOWN TRANSFER ENCOODING' if $DEBUG;
                return POE::Filter::SimpleHTTP::Error->new
                (
                    {
                        error => +UNKNOWN_TRANSFER_ENCODING,
                        context => $te
                    }
                );
			}
		}

		$message->content_ref(\$content);
	
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
