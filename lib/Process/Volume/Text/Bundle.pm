package Process::Volume::Text::Bundle;

use strict;
use warnings;

use Plack::Util;
use Plack::Util::Accessor qw( 
    access_stmts 
    display_name 
    institution 
    proxy 
    handle 
    bundle_format 
    file
    pages 
    total_pages
    is_partial
    output_filename 
    progress_filepath
    cache_dir
    download_url
    restricted 
    watermark
    watermark_filename 
    output_fh
    working_dir
    updater
    layout
    packager
);

use Builder;

use SRV::Utils;
use SRV::Globals;
use Institutions;

use File::Basename qw(basename dirname fileparse);
use File::Copy;
use File::Path qw(make_path remove_tree);
use File::Slurp;
use Data::Dumper;
use List::MoreUtils qw(any);
use POSIX qw(strftime);
use Time::HiRes;

use List::Util qw(max);
use Data::Dumper;
use IO::File;

use File::Temp qw(tempdir);

use POSIX qw(strftime);

use ISO639;

use Text::Wrap;
use IPC::Run;
use File::pushd;

our $COLOPHON_FILENAME = '00000000-hathitrust-colophon.txt';

sub new {
    my $proto = shift;
    my $class = ref $proto || $proto;

    my $self;
    if (@_ == 1 && ref $_[0] eq 'HASH') {
        $self = bless {%{$_[0]}}, $class;
    } else {
        $self = bless {@_}, $class;
    }

    $self;
}

sub process {
    my $self = shift;
    my $env = shift;

    my $C = $$env{'psgix.context'};
    my $mdpItem = $C->get_object('MdpItem');
    my $auth = $C->get_object('Auth');

    # will need to so something different for status
    my $working_dir = tempdir(DIR => $self->cache_dir, CLEANUP => 1);
    my @tmp = make_path($working_dir);
    $self->working_dir($working_dir);

    my $packager_class_name = "Package::Text::" . ( $mdpItem->Get('item_subclass') || "Volume" );
    my $packager_class = Plack::Util::load_class($packager_class_name);
    $self->packager($packager_class->new(
        mdpItem => $mdpItem,
        auth => $auth,
        updater => $self->updater,
        display_name => $self->display_name,
        institution => $self->institution,
        access_stmts => $self->access_stmts,
        restricted => $self->restricted,
        handle => $self->handle,
        working_dir => $working_dir,
        pages => $self->pages,
        is_partial => $self->is_partial,
        watermark => $self->watermark,
    ));

    eval {
        $self->packager->generate($env);
    };
    if ( my $err = $@ ) {
        die "COULD NOT GENERATE TEXT: $err";
    }

    $self->insert_colophon_page($env);

    if ( $self->bundle_format eq 'zip' ) {
        $self->updater->update(0, "Packing texts...");
        $self->pack_zip($env);
    } else {
        $self->updater->update(0, "Concatenating texts...");
        $self->concatenate_text($env);
    }

    my $do_rename = 1;

    # and then rename the output_file
    if ( $do_rename ) {
        rename($self->output_filename . ".download", $self->output_filename) || die $!;
    }

    $self->updater->finish();

    return {
        filename => $self->output_filename,
        mimetype => ( $self->bundle_format eq 'zip' ? "application/epub+zip" : "text/plain" )
    };
}

sub insert_colophon_page {
    my $self = shift;
    my ( $env ) = @_;

    my $C = $$env{'psgix.context'};
    my $mdpItem = $C->get_object('MdpItem');
    my $auth = $C->get_object('Auth');

    my $working_dir = $self->working_dir;

    my $display_name = $self->display_name;
    my $institution = $self->institution;
    my $access_stmts = $self->access_stmts;
    my $proxy = $self->proxy;

    my $publisher = $mdpItem->GetPublisher();
    my $title = wrap("Title:     ", "           ", $mdpItem->GetFullTitle());
    my $author = wrap("Author:    ", "           ", $mdpItem->GetAuthor());

    my $handle = SRV::Utils::get_itemhandle($mdpItem);

    my $contents = <<TEXT;
This file was downloaded from HathiTrust Digital Library.
Find more books at https://www.hathitrust.org.

$title
$author
Publisher: $publisher

Copyright:
$$access_stmts{stmt_head}
$$access_stmts{stmt_url}

TEXT

    $contents .= wrap("", "", $$access_stmts{stmt_text});

    $contents .= <<TEXT;

Find this book online: $handle

TEXT

    $contents .= wrap("", "", $self->packager->additional_message());
    $contents .= "\n\n";

    # watermarks!
    my ( $digitization_source, $collection_source ) = SRV::Utils::get_sources($mdpItem);
    my $watermark_text = "";
    if ( $digitization_source ) {
        my $name = Institutions::get_institution_inst_id_field_val($C, $collection_source, 'name');
        $watermark_text .= "Original from: $name\n";
    }
    if ( $digitization_source ) {
        my $name = Institutions::get_institution_inst_id_field_val($C, $digitization_source, 'name');
        $watermark_text .= "Digitized by:  $name\n";
    }

    $contents .= $watermark_text . "\n";

    # marginalia
    my @message = ('Generated');
    if ( $display_name ) {
        if ( $proxy ) {
            push @message, qq{by $display_name};
        }
        if ( $institution ) {
            push @message, qq{at $institution};
        }
        if ( $proxy ) {
            push @message, qq{for a print-disabled user};
        }
    }
    push @message, "on", strftime("%Y-%m-%d %H:%M GMT", gmtime());

    $contents .= wrap("", "", join(' ', @message)) . "\n";

    write_file("$working_dir/$COLOPHON_FILENAME", {binmode => ':utf8'}, $contents);


}

sub pack_zip {
    my $self = shift;
    my $env = shift;
    my $working_dir = $self->working_dir;
    my $zip_filename = $self->output_filename . ".download";
    my $ZIP_PROG = "/usr/bin/zip";

    if ( -f $zip_filename ) {
        # previous attempt
        unlink($zip_filename);
    }

    my $idx = 0;
    my $update_status = sub {
        my ( $buffer ) = @_;
        $idx += scalar grep(/adding:/, split(/\n/, $buffer));
        $self->updater->update($idx);
    };
    my $stderr;

    {
        my $dir = pushd($working_dir);
        IPC::Run::run([ $ZIP_PROG, "-r", $zip_filename, ".", '-x', '*.DS_Store' ], \undef, $update_status, \$stderr);
    }

    return $zip_filename;
}

sub concatenate_text {
    my $self = shift;
    my $env = shift;
    my $working_dir = $self->working_dir;

    my $i = 0;
    $self->updater->update($i);

    my $C = $$env{'psgix.context'};
    my $mdpItem = $C->get_object('MdpItem');

    my $ff = chr(12);

    my $text_filename = $self->output_filename . ".download";
    open(my $text_fh, ">", $text_filename);

    {
        my $dir = pushd($working_dir);
        my $input_fh;

        open($input_fh, '<', $COLOPHON_FILENAME);
        while ( <$input_fh> ) {
            print $text_fh $_;
        }

        print $text_fh $ff, "\n\n";

        foreach my $seq ( @{ $self->pages } ) {

            my $text_filename = $self->packager->get_file($seq, 'ocrfile');

            my $header = "p. (#$seq)";
            my $pg =  $mdpItem->GetPageNumBySequence( $seq );
            if ( $pg && $pg ne $seq ) {
                $header = "p. $pg (#$seq)";
            }

            print $text_fh "## $header " . ( '#' x ( 60 - length($header) - 3 ) ), "\n\n";

            open($input_fh, '<', $text_filename);
            while ( <$input_fh> ) {
                print $text_fh $_;
            }

            print $text_fh $ff, "\n\n" unless ( $seq eq $self->pages->[-1] );

            $i += 1;
            $self->updater->update($i);
        }

    }

    return $text_filename;
}

1;