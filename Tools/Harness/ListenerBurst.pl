use strict;
use warnings;
use Fcntl qw(O_CREAT O_EXCL O_WRONLY);

# Only the first helper emits a burst. Replacements stay idle.
if (sysopen(my $marker, $ENV{ISLANDBAR_LISTENER_PROBE_MARKER}, O_CREAT | O_EXCL | O_WRONLY)) {
    my $events = "{\"payload\":{}}\n" x 120;
    syswrite(STDOUT, $events) == length($events) or die "short write";
}
sleep 10;
