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

=head1 USAGE

  # Find and download (first) stream from HTTP page, record 60 minutes
  m3udownload.pl -f http://www.you-fm.de/music/you-fm-online-hoeren,webradio-102.html -d 60

=cut

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

# This should go into MP3::M3U::Parser
sub parse_ext_x_stream_inf {
    my($inf) = @_;
    $inf =~ m!^#EXT-X-STREAM-INF:(.*)$! or return;
    my %info = split /[=,]/, $1;
    \%info
}

# THis should go into some HTML meta parsing module, maybe
# HTML::ExtractMeta  does that already (but doesn't handle the URL)
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

        # We should have a switch for the type instead
        # or just guess it from the stream?!
        if( $title !~ /\.mp[g34]/ ) {
            $title .= ".mp4"; # assume video?!
            # We should fudge that later, and keep type+outname separate
        };
        $outname ||= $title;
        print "Found $content ($title)\n"
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

my $starttime = time;
my $stoptime;
if( $duration ) {
    $stoptime = $starttime + $duration;
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

            if( $stoptime ) {
                if( time > $stoptime ) {
                    close $fh;
                    return 0
                } else {
                    my $running = int((time - $starttime)/60);
                    print sprintf "[%d/%d] %s\r", $running, ($duration/60), $outname
                        unless $quiet;
                };
            } else {
                if( $headers->{"content-length"} and $written >= $headers->{"content-length"}) {
                    close $fh;
                    $completed++;
                    print sprintf "[%d/%d] %s\r", $completed, $total, $outname
                        unless $quiet;
                };
            };
            return 1
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
        system("ffmpeg -safe 0 -f concat -i join.txt -vcodec copy -acodec copy -bsf:a aac_adtstoasc \"$target\"")== 0
            or die "$! / $?";
        unlink @unlink;

        Future->done($target);
    }
}

sub local_name {
    my( $filename ) = @_;

    my $res;
    if( $outname ) {
        $res = strftime $outname, localtime;
    } else {
        $res = clean_fragment(basename $filename);
    }
    $res = File::Spec->catfile( $outdir, $res );
    return $res
}

for my $url (@ARGV) {

    fetch_m3u( $url )
    ->then(sub {
        my( $data, $url ) = @_;

        # Iterate over all entries (hoping that they are consecutive)
        # Fetch them all simultaneously
        # We should put a limit of (say) 4 requests in flight here ...
        my @downloads;
        my @files;
        $total = @{ $data->[0]->{data} };
        $completed = 0;
        for my $stream ( @{ $data->[0]->{data} }) {
            next if $stream->[0] =~ /^#/;
            my $target = $stream->[0];
            my $stream_source = URI->new_abs( $target, $url );
            $target =~ s!\?.*!!;

            if( $total > 1 ) {
                # Only multipart files need to go to a tempdir
                $target = File::Spec->catfile( $tempdir, $target );
            } else {
                # We can store it directly
                $target = local_name( $target );
            }
            verbose "Retrieving $stream_source to $target";
            push @files, $target;
            push @downloads, save_url( $stream_source, $target )
        };

        verbose "Waiting for downloads";
        my $download_finished = Future->wait_all( @downloads );

        # Now, how do we decide whether to combine all items from the playlist or not?!
        # For the time being, we know that .ts files want to be combined using ffmpeg:
        my $res = $download_finished;

        # Combine the files
        if( $total > 1 ) {
            $res = $download_finished->then( concat_files( \@files, local_name() ));
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