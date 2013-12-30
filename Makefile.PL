use 5.006;
use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                => 'REST::Consumer',
    AUTHOR              => q{Chris Becker <cbecker@shutterstock.com>, Travis Beck <travis@shutterstock.com>},
    VERSION_FROM        => 'lib/REST/Consumer.pm',
    ABSTRACT_FROM       => 'lib/REST/Consumer.pm',
    ($ExtUtils::MakeMaker::VERSION >= 6.3002
      ? ('LICENSE'=> 'perl')
      : ()),
    PL_FILES            => {},
    PREREQ_PM => {
        'Test::More'       => 0,
        'URI'              => 0,
        'HTTP::Request'    => 0,
        'LWP'              => 0,
        'JSON::XS'         => 0,
        'File::Path'       => 1.08,
    },
    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean               => { FILES => 'REST-Consumer-*' },
);
