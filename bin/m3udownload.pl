#!perl -w
use strict;
use Future;
use Data::Dumper;
use Getopt::Long;

# Use AnyEvent, AnyEvent::HTTP for the moment as downloader
use AnyEvent::HTTP;
use AnyEvent::Future 'as_future_cb';

use MP3::M3U::Parser;
use POSIX 'strftime';

GetOptions(
    'd|duration:s' => \my $duration,
    'o|outfile:s'  => \my $outname,
    'quiet'        => \my $quiet,
);

$outname ||= 'm3udownload-%Y%m%d-%H%M%S.mp3';

$duration ||= 60;
if( $duration =~ m!(\d+):(\d+)! ) {
    # hh:mm
    $duration = ($1 * 3600) + $2 * 60;
} else {
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

sub parse_m3u {
    my( $m3u ) = @_;
    
    my $parser = MP3::M3U::Parser->new;
    my $validm3u = eval {
        $parser->parse( \$m3u );
        1;
    };
    if( ! $validm3u ) {
        # retry with the #extm3u header:
        $m3u = "#EXTM3U\n$m3u";
        $parser->parse( \$m3u );
    };
    
    Future->wrap( $parser->result )
    
}

my $stoptime = time + $duration;
warn strftime "Recording until %H:%M:%S", localtime $stoptime
    unless $quiet;
for my $url (@ARGV) {
    request( 'GET' => $url)
    ->then(sub {
        my( $body, $headers ) = @_;
        
        parse_m3u( $body );
    })->then(sub {
        my( $data ) = @_;
        my $stream_source = $data->{data}->[0]->[0];
        
        my $outfile = strftime $outname, localtime;
        warn "Writing to $outfile"
            unless $quiet;

        open my $fh, '>', $outfile
            or die "Couldn't save to '$outfile': $!";
        binmode $fh;

        request(
            'GET' => $stream_source,
            on_body => sub {
                my( $body, $headers ) = @_;
                print {$fh} $body;
                
                time < $stoptime
            }
        );
    })->await;
}
