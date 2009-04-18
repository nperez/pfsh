package POE::Filter::SimpleHTTP;

use warnings;
use strict;

use Data::Dumper;

use HTTP::Status;
use HTTP::Response;
use HTTP::Request;

use Compress::Zlib;

use Regexp::Common;
use POE::Filter::SimpleHTTP::Regex;

use base('POE::Filter');

use bytes;

use constant
{
	'RAW_BUFFER'		=> 0,
	'PREAMBLE_BUFFER'	=> 1,
	'HEADER_BUFFER'		=> 2,
	'CONTENT_BUFFER'	=> 3,
	'LEFT_OVERS'		=> 4,
	'PREAMBLE_COMPLETE'	=> 5,
	'HEADER_COMPLETE'	=> 6,
	'CONTENT_COMPLETE'	=> 7,
};

our $VERSION = '0.01';

sub new()
{
	my ($class, $options) = @_;

	my $self = [];

	$self->[+RAW_BUFFER]		= [];
	$self->[+PREAMBLE_BUFFER] 	= [];
	$self->[+HEADER_BUFFER] 	= [];
	$self->[+CONTENT_BUFFER] 	= [];
	$self->[+PREAMBLE_COMPLETE]	= 0;
	$self->[+HEADER_COMPLETE] 	= 0;
	$self->[+CONTENT_COMPLETE] 	= 0;

	return bless($self, $class);
}

sub reset()
{
	my ($self) = @_;

	$self->[+RAW_BUFFER]        = [];
	$self->[+PREAMBLE_BUFFER]   = [];
	$self->[+HEADER_BUFFER]     = [];
	$self->[+CONTENT_BUFFER]    = [];
	$self->[+PREAMBLE_COMPLETE] = 0;
	$self->[+HEADER_COMPLETE]   = 0;
	$self->[+CONTENT_COMPLETE]  = 0;
}

sub get_one()
{
	my ($self) = @_;
	
	my $buffer = '';

	while(defined(my $raw = shift(@{$self->[+RAW_BUFFER]})) || length($buffer))
	{
		$buffer .= $raw if defined($raw);

		if(!$self->[+PREAMBLE_COMPLETE])
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
					my $match = $self->get_chunk(\$buffer);
					push(@{$self->[+PREAMBLE_BUFFER]}, $match);
					$self->[+PREAMBLE_COMPLETE] = 1;

				} else {
					
					return undef;

					# XXX The first line just didn't parse
					# XXX Decide the error state and what gets returned
				}
			}

		} elsif(!$self->[+HEADER_COMPLETE]) {
			
			if($buffer =~ /^\x0D\x0A/)
			{
				substr($buffer, 0, 2, '');
				$self->[+HEADER_COMPLETE] = 1;
			
			} else {
				
				#gather all of the headers from this chunk
				while($buffer =~ $POE::Filter::SimpleHTTP::Regex::HEADER 
					and $buffer !~ /^\x0D\x0A/)
				{
					my $match = $self->get_chunk(\$buffer);
					push(@{$self->[+HEADER_BUFFER]}, $match);
				}

			}

		} elsif(!$self->[+CONTENT_COMPLETE]) {
			
			if($buffer =~ /^\x0D\x0A/)
			{
				substr($buffer, 0, 2, '');
				$self->[+CONTENT_COMPLETE] = 1;

			} else {
				
				if(index($buffer, "\x0D\x0A") == -1)
				{
					push(@{$self->[+CONTENT_BUFFER]}, $buffer);
				
				} else {

					my $match = $self->get_chunk(\$buffer);
					push(@{$self->[+CONTENT_BUFFER]}, $match);
				}

			}

		} else {
		
			return undef;
			# XXX We have left overs
			# XXX Decide an error state and what gets returned
		
		}
	}
		
	if($self->[+CONTENT_COMPLETE])
	{
		return [$self->build_message()];
	}
	else
	{
		warn Dumper($self);
		return [];
	}
}

sub get_one_start()
{
	my ($self, $data) = @_;
	
	if(!ref($data))
	{
		$data = [$data];
	}

	push(@{$self->[+RAW_BUFFER]}, @$data);
	
}

sub put()
{
}


sub get_chunk()
{
	my ($self, $buffer) = @_;

	#find the break
	my $break = index($$buffer, "\x0D\x0A");
	
	my $match;
	if($break == -1)
	{
		#pullout the whole string
		$match = substr($$buffer, 0, length($$buffer), '');
	
	} elsif($break > 0) {
		
		#pull out string until newline
		$match = substr($$buffer, 0, $break, '');
		
		#remove the CRLF from the buffer
		substr($$buffer, 0, 2, '');
	
	} else {

		# XXX We shouldn't get here
		return undef;
	}


	return $match;
}

sub build_message()
{
	my ($self) = @_;
	
	my $message;

	my ($preamble) = @{$self->[+PREAMBLE_BUFFER]};

	if($preamble =~ $POE::Filter::SimpleHTTP::Regex::REQUEST)
	{
		my ($method, $uri) = ($1, $2);

		$message = HTTP::Request->new($method, $uri);
	
	} elsif($preamble =~ $POE::Filter::SimpleHTTP::Regex::RESPONSE) {
	
		my ($code, $text) = ($2, $3);

		$message = HTTP::Response->new($code, $text);
	
	} else {

		die q/Something didn't match!/;
	}


	foreach my $line (@{$self->[+HEADER_BUFFER]})
	{
		if($line =~ $POE::Filter::SimpleHTTP::Regex::HEADER)
		{
			$message->header($1, $2);
		}
	}

	warn Dumper($message);
	
	# If we have a transfer encoding, we need to decode it 
	# (ie. unchunkify, decompress, etc)
	if($message->header('Transfer-Encoding'))
	{
		warn 'INSIDE TE';
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

		while( my $content_line = shift(@{$self->[+CONTENT_BUFFER]}) )
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
						while( my $tline = shift(@{$self->[+CONTENT_BUFFER]}) )
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
				my $subline = shift(@{$self->[+CONTENT_BUFFER]});
				
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
			warn 'CHUNKED ISNT LAST';
			return undef;
			# XXX Determine error state for the chunked not being the last 
			# Transfer-Encoding
		}

		foreach my $te (@$te_s)
		{
			if($te =~ /deflate/)
			{
				my ($inflate, $status) = Compress::Zlib::inflateInit();
				if(!defined($inflate))
				{
					warn 'INFLATE FAILED TO INIT';
					return undef;
					# XXX Do something with the error $status
				}
				else
				{
					my ($buffer, $status) = $inflate->(\$buffer);
					if($status != +Z_OK or $status != +Z_STREAM_END)
					{
						warn 'INFLATE FAILED TO WORK';
						return undef;
						# XXX Do something with the error $status
					}
				}
			
			} elsif($te =~ /compress/) {

				$buffer = Compress::Zlib::uncompress(\$buffer);
				if(!defined($buffer))
				{
					warn 'COMPRESS FAILED TO WORK';
					return undef;
					# XXX Do something with the error
				}

			} elsif($te =~ /gzip/) {

				$buffer = Complress::Zlib::memGunzip(\$buffer);
				if(!defined($buffer))
				{
					warn 'GUNZIP FAILED';
					return undef;
					# XXX Do something with the error $status
				}
			
			} else {
					
					warn 'UNKNOWN TE';
					return undef;
				# XXX Do something with the error $status
			}
		}

		$message->content_ref(\$buffer);
	
	} else {

		$message->add_content($_) for @{$self->[+CONTENT_BUFFER]};
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
