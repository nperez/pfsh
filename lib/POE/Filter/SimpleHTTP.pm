package POE::Filter::SimpleHTTP;

use warnings;
use strict;

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

sub get_one()
{
	my ($self) = @_;

	foreach my $raw (@{$self->[+RAW_BUFFER]})
	{
		if(!$self->[+PREAMBLE_COMPLETE])
		{
			if($raw =~ /^\x0D\x0A?|\x0A\x0D?/)
			{
				next;
			
			} else {
				
				if($RE{'PFSH'}->{'request'}->matches($raw)
					or $RE{'PFSH'}->{'response'}->matches($raw)) 
				{
					push(@{$self->[+PREAMBLE_BUFFER]}, $raw);
					$self->[+PREAMBLE_COMPLETE] = 1;

				} else {

					# XXX The first line just didn't parse
					# XXX Decide the error state and what gets returned
				}
			}

		} elsif(!$self->[+HEADER_COMPLETE]) {

			if($raw =~ /^\x0D\x0A?|\x0A\x0D?/)
			{
				$self->[+HEADER_COMPLETE] = 1;
			
			} else {

				push(@{$self->[+HEADER_BUFFER]}, $raw);
			}

		} elsif(!$self->[+CONTENT_COMPLETE]) {

			if($raw =~ /^\x0D\x0A?|\x0A\x0D?/)
			{
				$self->[+CONTENT_COMPLETE] = 1;

			} else {

				push(@{$self->[+CONTENT_BUFFER]}, $raw);
			}
		} else {
			
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
	
	foreach(@$data)
	{
		push
		(
			@{$self->[+RAW_BUFFER]}, 
			split
			(
				/\x0D\x0A?|\x0A\x0D?/,
				$_,
			),
		);
	}
}

sub put()
{
}

sub build_message()
{
	my ($self) = @_;
	
	my $message;

	if($RE{'PFSH'}->{'request'}->{'-keep'}->matches($self->[+PREAMBLE_BUFFER]))
	{
		my ($method, $uri) = ($1, $2);

		$message = HTTP::Request->new($method, $uri);
	
	} elsif($RE{'PFSH'}->{'response'}->{'-keep'}
		->matches($self->[+PREAMBLE_BUFFER])) {
	
		my ($code, $text) = ($2, $3);

		$message = HTTP::Response->new($code, $text);
	}

	foreach my $line (@{$self->[+HEADER_BUFFER]})
	{
		if($RE{'PFHS'}->{'header'}->{'-keep'}->matches($line))
		{
			my ($key, $value) = ($1, $2);
			$message->header($key, $value);
		}
	}
	
	# If we have a transfer encoding, we need to decode it 
	# (ie. unchunkify, decompress, etc)
	if($message->header('Transfer-Encoding'))
	{
		my $te_raw = $message->header('Transfer-Encoding');
		my $te_s = 
		\@{ 
			map 
			{ 
				my ($token) = split(/;/, $_); $token; 
			} 
			(reverse(split(/,/, $te_raw)))
		};
		
		my $buffer = '';
		my $subbuff = '';
		my $size = 0;

		while( my $line = shift(@{$self->[+CONTENT_BUFFER]}) )
		{
			# Start of a new chunk
			if($size == 0 and length($subbuff) == 0)
			{
				$line =~ /^([\dA-Fa-f]+).*\x0D\x0A?|\x0A\x0D?/;
				$size = hex($1);
				
				# If we got a zero size, it means time to process trailing 
				# headers if enabled
				if($size == 0)
				{
					if($message->header('Trailer'))
					{
						while( my $tline = shift(@{$self->[+CONTENT_BUFFER]}) )
						{
							if($RE{'PFHS'}->{'header'}->{'-keep'}
								->matches($tline))
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
			
			my $offset = 0;

			while($size > 0)
			{
				my $subline = shift(@{$self->[+CONTENT_BUFFER]});
				
				while(length($subline))
				{
					$subbuff .= substr($subline, $offset, 4096, '');
					$size -= length($subbuff);
					$offset += length($subbuff);
				}
			}

			$buffer .= substr($subbuff, 0, length($subbuff), '');
		}
		
		my $chunk = shift(@$te_s);
		if($chunk !~ /chunked/)
		{
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
					# XXX Do something with the error $status
				}
				else
				{
					my ($buffer, $status) = $inflate->(\$buffer);
					if($status != +Z_OK or $status != +Z_STREAM_END)
					{
						# XXX Do something with the error $status
					}
				}
			
			} elsif($te =~ /compress/) {

				$buffer = Compress::Zlib::uncompress(\$buffer);
				if(!defined($buffer))
				{
					# XXX Do something with the error
				}

			} elsif($te =~ /gzip/) {

				$buffer = Complress::Zlib::memGunzip(\$buffer);
				if(!defined($buffer))
				{
					# XXX Do something with the error $status
				}
			
			} else {

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
