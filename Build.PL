use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
    module_name         => 'POE::Filter::SimpleHTTP',
    license             => 'gpl',
    dist_author         => 'Nicholas R. Perez <nicholasrperez@gmail.com>',
    dist_version_from   => 'lib/POE/Filter/SimpleHTTP.pm',
    build_requires => {
        'Test::More' => 0,
    },
    add_to_cleanup      => [ 'POE-Filter-SimpleHTTP-*' ],
);

$builder->create_build_script();
