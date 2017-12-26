#!perl -w
use strict;
use Future;
use Data::Dumper;
use Getopt::Long;

# Use AnyEvent, AnyEvent::HTTP for the moment as downloader
use AnyEvent::HTTP;
use AnyEvent::Future 'as_future_cb';

use URI;
use MP3::M3U::Parser;
use POSIX 'strftime';
use JSON 'decode_json';
use File::Spec;
use File::Temp 'tempdir';
use File::Path 'remove_tree';
use Text::CleanFragment;

GetOptions(
    'd|duration:s' => \my $duration,
    'o|outfile:s'  => \my $outname,
    'output-directory:s' => \my $outdir,
    'f|force'      => \my $parse_html,
    'quiet'        => \my $quiet,
    'debug'        => \my $debug,
);

$|++;
$outdir ||= '.';
my $tempdir = tempdir();

sub verbose($) {
    print "$_[0]\n" if $debug;
}

if( ! $parse_html ) {
    $outname ||= 'm3udownload-%Y%m%d-%H%M%S.mp3';
};

if( $duration =~ m!(\d+):(\d+)! ) {
    # hh:mm
    $duration = ($1 * 3600) + $2 * 60;
} elsif( $duration ) {
    # minutes
    $duration = $duration * 60;
}

sub request {
    my( @args ) = @_;

    as_future_cb {
        my ( $done, $fail ) = @_;
        http_request(
            GET => $args[1],
            @args,
            $done
            #cb => $done,
        )
    }
}

sub parse_ext_x_stream_inf {
    my($inf) = @_;
    $inf =~ m!^#EXT-X-STREAM-INF:(.*)$! or return;
    my %info = split /[=,]/, $1;
    \%info
}

sub parse_main_title {
    my( $html, $url ) = @_;

    my $title;
    if( $html =~ m!<script\s+type="application/ld\+json"\s*>(.*?);?</script\s*>!mis) {
        my $json = $1;
        $json =~ s!,\s*\}!}!g;
        $json =~ s!,\s*\]!]!g;
        my $metadata = decode_json( $json );
        $title = $metadata->{name}
    } elsif( $html =~ m!<meta\s+name="og:title" content="([^<"]+)"\s*>!is) {
        $title = $1;
    } elsif( $url =~ m!/([^/]+?)(?:\.html?)?$!is) {
        $title = $1;
    }

    return clean_fragment( $title );
}

sub parse_html {
    my( $html, $base ) = @_;
    if( $html =~ m!"(https?://[^"]+\.m3u8?\b[^"]*)"!si) {
        my $content = URI->new_abs( $1, $base );
        my $title = parse_main_title( $html, $base );
        if( $title !~ /\.mp4/ ) {
            $title .= ".mp4";
        };
        $outname ||= $title;
        print "Found $content ($title)"
            unless $quiet;
        return fetch_m3u( $content )
    } else {
        print "Couldn't find any M3U in HTML\n";
        print $html;
    }
}

sub parse_m3u {
    my( $m3u, $base ) = @_;

    my $parser = MP3::M3U::Parser->new;

    verbose "Parsing $m3u";

    my $validm3u = eval {
        $parser->parse( \$m3u );
        1;
    };
    if( ! $validm3u ) {
        # retry with the #extm3u header:
        $m3u = "#EXTM3U\n$m3u";
        $parser->parse( \$m3u );
    };

    verbose Dumper $parser->result;

    # If we have a stream, find the highest resolution and return that, for
    # further resolving, later on:
    my $res = $parser->result;

    if( $res->[0]->{data}->[0]->[0] =~ m!^#EXT-X-STREAM-INF:! ) {
        verbose "Found multiple playlists";
        my @streams;
        $res = $res->[0]->{data};
        for my $i (0.. (@$res/2) -1) {
            push @streams, parse_ext_x_stream_inf( $res->[$i*2]->[0] );
            $streams[-1]->{url} = $res->[$i*2+1]->[0];
        };

        # now, find the stream with the highest bandwidth
        @streams = sort { $b->{BANDWIDTH} <=> $a->{BANDWIDTH} } @streams;
        my $highest = $streams[0];
        my $url = URI->new_abs( $highest->{url}, $base );

        verbose "Redirecting to $url";
        return fetch_m3u( $url );

    } else {
        return Future->wrap( $res, $base )
    }
}

sub fetch_m3u {
    my( $url ) = @_;
    request( 'GET' => $url)
    ->then(sub {
        my( $body, $headers ) = @_;
        warn Dumper $headers
            unless $headers->{Status} =~ /^2../;
        if( $parse_html and $headers->{"content-type"} =~ m!^text/html\b! ) {
            return parse_html( $body, $url )
        } else {
            return parse_m3u( $body, $url );
        }
    })
}

my $stoptime;
if( $duration ) {
    $stoptime = time + $duration;
    print strftime "Recording until %H:%M:%S\n", localtime $stoptime
        unless $quiet;
};

my $total;
my $completed;

sub save_url {
    my( $url, $filename ) = @_;

    open my $fh, '>', $filename
        or die "Couldn't save to '$filename': $!";
    binmode $fh;

    my $written;
    return request(
        'GET' => $url,
        on_body => sub {
            my( $body, $headers ) = @_;
            print {$fh} $body;

            $written += length $body;
            if( $headers->{"content-length"} and $written >= $headers->{"content-length"}) {
                close $fh;
                $completed++;
                print sprintf "[%d/%d] %s\r", $completed, $total, $outname;
            };

            if( $stoptime ) {
                close $fh;
                return time < $stoptime
            } else {
                return 1
            }
        }
    );
}

sub concat_files {
    my ($files, $target) = @_;

    return sub {
        my @unlink = ('join.txt');
        open my $list, '>', 'join.txt' or die "$!";
        for my $f (@$files) {
            push @unlink, $f;
            print {$list} "file '$f'\n";
        }

        close $list;

        # Now, join the files
        $ENV{PATH} = "c:\\Users\\corion\\Projekte\\App-ShaderToy\\;" . $ENV{PATH};
        system("ffmpeg -safe 0 -f concat -i join.txt -vcodec copy -acodec copy -bsf:a aac_adtstoasc \"$target\"")== 0
            or die "$! / $?";
        unlink @unlink;

        Future->done($target);
    }
}

for my $url (@ARGV) {
    fetch_m3u( $url )
    ->then(sub {
        my( $data, $url ) = @_;

        # Iterate over all entries (hoping that they are consecutive)
        # Fetch them all simultaneously
        my @downloads;
        my @files;
        $total = @{ $data->[0]->{data} };
        $completed = 0;
        for my $stream ( @{ $data->[0]->{data} }) {
            next if $stream->[0] =~ /^#/;
            my $target = $stream->[0];
            my $stream_source = URI->new_abs( $target, $url );
            $target =~ s!\?.*!!;

            if( $target !~ /\.ts/ and $outname ) {
                $target = strftime $outname, localtime;
            };

            $target = File::Spec->catfile( $tempdir, $target );
            verbose "Retrieving $stream_source to $target";
            push @files, $target;
            push @downloads, save_url( $stream_source, $target )
        };

        verbose "Waiting for downloads";
        my $download_finished = Future->wait_all( @downloads );

        # Now, how do we decide whether to combine all items from the playlist or not?!
        # For the time being, we know that .ts files want to be combined using ffmpeg:
        my $res = $download_finished;
        if( $files[0] =~ /\.ts$/ ) {
            my $final_file = File::Spec->catfile( $outdir, $outname );
            $res = $download_finished->then( concat_files( \@files, $final_file ));
        }
        $res

    })->await;
}

remove_tree(
    $tempdir,
    {
        safe => 1,
    }
);