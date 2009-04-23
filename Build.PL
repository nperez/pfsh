use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
    module_name         => 'POE::Filter::SimpleHTTP',
    license             => 'gpl',
    dist_author         => 'Nicholas Perez <nperez@cpan.org>',
    dist_version_from   => 'lib/POE/Filter/SimpleHTTP.pm',
    dist_abstract       => 'A simple client/server HTTP filter for POE',
    create_readme       => 1,
    build_requires      => 
    {
        'Test::More'        => 0,
        'Moose'             => 0.75,
        'Regexp::Common'    => 2.122,
        'LWP'               => 5.822,
        'URI'               => 1.37,
        'Compress::Zlib'    => 2.012,
        'UNIVERSAL::isa'    => 1.01,
    },
    add_to_cleanup      => [ 'POE-Filter-SimpleHTTP-*' ],
    meta_merge          => 
    {
        resources       => 
        {
            repository => 'http://github.com/nperez/pfsh/tree/master'
        }
    }
);

$builder->create_build_script();
