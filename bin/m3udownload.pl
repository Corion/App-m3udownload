#!perl -w
use strict;
use Future;
use Data::Dumper;
use Getopt::Long;

use FindBin '$Bin';
use lib "$Bin/../../Promises-RateLimiter/lib";

# Use AnyEvent, AnyEvent::HTTP for the moment as downloader
use AnyEvent::HTTP;
use AnyEvent::Future 'as_future_cb';
use Future::Limiter;

use URI;
use MP3::M3U::Parser;
use POSIX 'strftime';
use JSON 'decode_json';
use File::Spec;
use File::Temp 'tempdir';
use File::Basename;
use Text::CleanFragment;

=head1 USAGE

  # Find and download (first) stream from HTTP page, record 60 minutes
  m3udownload.pl -f http://www.you-fm.de/music/you-fm-online-hoeren,webradio-102.html -d 60

  # Download video stream
  m3udownload.pl http://www.streambox.fr/playlists/test_001/stream.m3u8 -o arte.mp4

=head1 OPTIONS

=over 4

=item C<--duration>

Duration of recording. This is the duration in wall clock time, not the length
of the stream.

=head1 DESCRIPTION

C<m3udownload.pl> downloads HLS streams usually encoded as M3U playlists and
saves them as a single file. It can also extract M3U links from an HTML page
for convenient quick launch from external tools.

=head1 LIMITATIONS

Currently, this client does not yet support re-fetching the playlist to find
new segments added to the playlist according to
L<https://tools.ietf.org/html/draft-pantos-http-live-streaming-23#section-6.2.1>
.

=cut

GetOptions(
    'd|duration:s'       => \my $duration,
    'o|outfile:s'        => \my $outname,
    'output-directory:s' => \my $outdir,
    't|output-type:s'    => \my $outtype,
    'f|force'            => \my $parse_html,
    'quiet'              => \my $quiet,
    'debug'              => \my $debug,
);

$|++;
$outdir ||= '.';
my $tempdir = tempdir( CLEANUP => 1 );

my $limiter = Future::Limiter->new(
    maximum => 4,
);

our $stream_title; # will store the (page) title

sub verbose($) {
    print "$_[0]\n" if $debug;
}

if( ! $parse_html ) {
    $outname ||= 'm3udownload-%Y%m%d-%H%M%S';
};

if( $duration and $duration =~ m!(\d+):(\d+)! ) {
    # hh:mm
    $duration = ($1 * 3600) + $2 * 60;
} elsif( $duration ) {
    # minutes
    $duration = $duration * 60;
}

sub request {
    my( @args ) = @_;

    my( $url ) = URI->new( $args[1] );
    my $host = $url->host;
    $limiter->limit($host)
    ->then(sub {
        my( $token ) = @_;
        my $res = AnyEvent::Future->new();

        my $handle;
        $handle = http_request(
            GET => $args[1],
            @args,
            sub { undef $token; undef $handle; $res->done( @_ ) }
        );
        $res
    })
}

# This should go into MP3::M3U::Parser
sub parse_ext_x_stream_inf {
    my($inf) = @_;
    $inf =~ m!^#EXT-X-STREAM-INF:(.*)$! or return;
    my $i = $1;
    my %info = $i =~ /([^,]+)=("(?:[^"]+)"|(?:[^,="]+))/g;
    \%info
}

# This should go into some HTML meta parsing module, maybe
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
            #$title .= ".mp4"; # assume video?!
            # We should fudge that later, and keep type+outname separate
        };
        $stream_title = $title;

        print "Found $content ($stream_title)\n"
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

    # Fudge the m3u as M3U::Parser doesn't seen to handle empty lines well?!
    $m3u =~ s!(\r?\n)+(\r?\n)!$2!g;

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

    # Filter/reparse the results :-/
    # https://bitdash-a.akamaihd.net/content/MI201109210084_1/m3u8s/f08e80da-bf1d-4e3d-8899-f0f6155f6efa.m3u8

    my @items = @{ $res->[0]->{data} };
    shift @items
        while( @items
               and $items[0]->[0] =~ /^#/ and
               $items[0]->[0] !~ m!#EXT-X-STREAM-INF:! );

    if( $items[0]->[0] =~ m!^#EXT-X-STREAM-INF:! ) {
        verbose "Found multiple playlists";
        my @streams;
        #$res = $res->[0]->{data};
        for my $i (0.. (@items/2) -1) {
            push @streams, parse_ext_x_stream_inf( $items[$i*2]->[0] );
            $streams[-1]->{url} = $items[$i*2+1]->[0];
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
    request( 'GET' => $url )
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

my $last_progress = '';
sub download_progress {
    my( $current, $total, $visual ) = @_;
    unless( $quiet ) {
        my $progress = sprintf "[%d/%d] %s\r", $current, $total, $visual;
        print $progress
            if $last_progress ne $progress;
        $last_progress = $progress;
    }
}

sub save_url {
    my( $url, $filename, $target_visual ) = @_;

    open my $fh, '>', $filename
        or die "Couldn't save to '$filename': $!";
    binmode $fh;

    my $written;
    return request(
        'GET' => $url,
        on_body => sub {
            my( $body, $headers ) = @_;

            if( $headers->{Status} =~ /^[45]/ ) {
                my $msg = join ":", $headers->{URL}, $headers->{Reason};
                warn "$msg\n";
                return 0;
            };
            print {$fh} $body;

            $written += length $body;

            if( $stoptime ) {
                if( time > $stoptime ) {
                    close $fh;
                    return 0
                } else {
                    my $running = int((time - $starttime)/60);
                    download_progress( $running, ($duration/60), $target_visual );
                };
            } else {
                if( $headers->{"content-length"} and $written >= $headers->{"content-length"}) {
                    close $fh;
                    $completed++;
                    download_progress( $completed, $total, $target_visual );
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
        system("ffmpeg -y -safe 0 -f concat -i join.txt -vcodec copy -acodec copy -bsf:a aac_adtstoasc \"$target\"") == 0
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

    } elsif( $stream_title ) {
        $res = clean_fragment($stream_title);

    } else {
        $res = clean_fragment(basename $filename);
    }

    if( $outname ) {
        # The user specified the output filename extension, nothing to guess

    } elsif( $outtype ) {
        # Do something like stripping an extension if there is any:
        $res =~ s!(\.\w+)$!!;
        $res .= ".$outtype";

    } elsif( defined $filename and $filename =~ /(\.\w+)$/ ) {
        # (re)use the extension of the filename
        $res .= $1

    } else {
        # We don't know what to do with the extension, so we'll assume the
        # maximum possible and try to output/convert to .mp4
        $res .= '.mp4'
    }

    $res = File::Spec->catfile( $outdir, $res );
    return $res
}

for my $url (@ARGV) {

    fetch_m3u( $url )
    ->then(sub {
        my( $data, $url ) = @_;

        # Iterate over all entries (hoping that they are consecutive)
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
                # We should use tempfile() here, to avoid clashes?!
                $target = File::Spec->catfile( $tempdir, basename($target) );
            } else {
                # We can store it directly
                $target = local_name( $target );
            }
            verbose "Retrieving $stream_source to $target";
            push @files, $target;
            my $v = $stream_title || basename($url);
            push @downloads, save_url( $stream_source, $target, $v )
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

    })
    ->catch(sub {
        die "@_"
    })->await;
}
