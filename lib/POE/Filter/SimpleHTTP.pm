package POE::Filter::SimpleHTTP;

use warnings;
use strict;

use HTTP::Status;
use HTTP::Response;
use HTTP::Request;

use POE::Filter::SimpleHTTP::Regex;

use base('POE::Filter');

use constant
{
	'RAW_BUFFER'		=> 0,
	'HEADER_BUFFER'		=> 1,
	'CONTENT_BUFFER'	=> 2,
}


our $VERSION = '0.01';



sub new()
{
}

sub get_one()
{
}

sub get_one_start()
{
}

sub put()
{
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
