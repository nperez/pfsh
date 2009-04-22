package POE::Filter::SimpleHTTP::Error;
use Moose;
use Moose::Util::TypeConstraints;

use warnings;
use strict;

use constant
{
   UNPARSABLE_PREAMBLE          => 0,
   TRAILING_DATA                => 1,
   CHUNKED_ISNT_LAST            => 2,
   INFLATE_FAILED_INIT          => 3,
   INFLATE_FAILED_INFLATE       => 4,
   UNCOMPRESS_FAILED            => 5,
   GUNZIP_FAILED                => 6,
   UNKNOWN_TRANSFER_ENCODING    => 7,
};

use base('Exporter');

our @EXPORT = qw/ UNPARSABLE_PREAMBLE TRAILING_DATA CHUNKED_ISNT_LAST 
    INFLATE_FAILED_INIT INFLATE_FAILED_INFLATE UNCOMPRESS_FAILED
    GUNZIP_FAILED UNKNOWN_TRANSFER_ENCODING /;

subtype 'ErrorType'
    => as 'Int'
    => where { -1 < $_ && $_ < 8 }
    => message { 'Invalid ErrorType' };

has 'error' =>
(
    is => 'rw',
    isa => 'ErrorType'
);

has 'context' =>
(
    is => 'rw',
    isa => 'Str',
);


1;
