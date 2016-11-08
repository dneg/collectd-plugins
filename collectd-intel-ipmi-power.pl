#!/usr/bin/perl
#
# collectd plugin for reading intel node manager power stats
# aggregates readings from multiple nodes (e.g. 4 in 2U systems) into a summary
# James Braid <jamesb@loreland.org>
#

use strict;
use Data::Dumper;
use IPC::Cmd qw(can_run run);
use Log::Log4perl qw(:easy :no_extra_logdie_message);
use Getopt::Long;

my $OPT = {};

Log::Log4perl->init(\ <<'EOT');
log4perl.logger = DEBUG, Syslog
log4perl.appender.Screen = Log::Log4perl::Appender::Screen
log4perl.appender.Screen.layout = PatternLayout
log4perl.appender.Screen.layout.ConversionPattern = %F{1}: %p: %m{chomp}%n
log4perl.appender.Syslog = Log::Dispatch::Syslog
log4perl.appender.Syslog.ident = collectd-intel-ipmi-power
log4perl.appender.Syslog.logopt = pid
log4perl.appender.Syslog.facility = daemon
log4perl.appender.Syslog.layout = SimpleLayout
log4perl.appender.Syslog.Threshold = INFO
EOT

GetOptions($OPT,
    'chassis=s@',
    'interval=s' => \$ENV{COLLECTD_INTERVAL},
    'debug' => sub { get_logger->level($DEBUG) },
) or LOGDIE "options parsing failed: $!";

my $interval = $ENV{COLLECTD_INTERVAL} || 60;

# did we get any arugments?
LOGDIE "no chassis names specified" if (!$OPT->{chassis});

# check if ipmi-oem is installed and bail out if it's missing
my $ipmi_oem = can_run('ipmi-oem');
LOGDIE "can't find ipmi-oem" if (!$ipmi_oem);

INFO sprintf "starting for [%s]", (join " ", @{$OPT->{chassis}});

# loop forever polling each chassis
while (1) {
    foreach my $chassis (@{$OPT->{chassis}}) {
        #INFO "doing $chassis";
        __get_ipmi_one_chassis($chassis);
    }
    sleep $interval;
}

sub __get_ipmi_one_chassis {
    my $chassis_name = shift;
    my $s = {};
    my $summary = {};
    my $nodes = {};

    # how many nodes we expect to read per chassis, and our hostname format
    my $expected_nodes = 4;
    my $hostname = sprintf '%sbm[1-%d]', $chassis_name, $expected_nodes;
    my $ipmi_cmd = sprintf '%s -Q -u root -p password -h "%s" intelnm get-node-manager-statistics', $ipmi_oem, $hostname;

    my $output;
    my $res = scalar run(command => $ipmi_cmd, verbose => 0, buffer => \$output, timeout => 10);

    WARN "$chassis_name: ipmi-oem failed: $!: $res" if (!$res && !$output);

    my @lines = split /\n/, $output;

    foreach my $line (@lines) {
        chomp $line;

        # parse lines like
        # c531bm1: Average Power                                 : 204 Watts
        # c531bm1: Power Statistics Reporting Period             : 468060 seconds
        # c531bm1: Power Global Administrative State             : Enabled
        if ($line =~ /(\w+): ([\w+\s]+): ([\d]+)/) {
            my ($hostname, $key, $value) = ($1, $2, $3);
            $key =~ s/\s+$//g;
            $s->{$hostname}->{$key} = $value;

            $summary->{$key} = 0 if (!exists $summary->{$key});
            $summary->{$key} += $value;
            $nodes->{$hostname} = 1;
        }
    }

    my $node_count = (int keys %$nodes);
    if ($node_count != $expected_nodes) {
        WARN "$chassis_name: got $node_count, wanted $expected_nodes nodes";
        return 1;
    }

    my $current_power = $summary->{'Current Power'};

    DEBUG "$chassis_name: $current_power watts";

    # send a value list to collectd. set the hostname to the current chassis we
    # are grabbing data for
    my $output = sprintf 'PUTVAL "%s/intel_ipmi_power/power-current_power" interval=%s N:%d', $chassis_name, $interval, $current_power;

    DEBUG $output;
    print "$output\n";
}

