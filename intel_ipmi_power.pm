#!/usr/bin/perl
#
# collectd plugin for reading intel node manager power stats
# aggregates readings from multiple nodes (e.g. 4 in 2U systems) into a summary
# James Braid <jamesb@loreland.org>
#
# collectd.conf snippet:
# <Plugin "perl">
#   BaseName "Collectd::Plugins"
#   LoadPlugin "intel_ipmi_power"
#
#   <Plugin intel_ipmi_power>
#     Chassis "c123" "c124" "c125"
#   </Plugin>
# </Plugin>
#

package Collectd::Plugins::intel_ipmi_power;
use strict;
use Data::Dumper;
use Collectd qw(:all);
use IPC::Cmd qw(can_run run);

my $plugin_name = 'intel_ipmi_power';
my $chassis_name;
my $ipmi_oem;

plugin_register(TYPE_CONFIG, $plugin_name, 'intel_ipmi_power_config');
plugin_register(TYPE_INIT, $plugin_name, 'intel_ipmi_power_init');
plugin_register(TYPE_READ, $plugin_name, 'intel_ipmi_power_read');

sub intel_ipmi_power_init {
    # collectd fiddles with SIGCHLD which makes it impossible to monitor child
    # processes from a plugin, so restore the default SIGCHLD handler
    $SIG{CHLD} = 'DEFAULT';

    # check if ipmi-oem is installed and bail out if it's missing
    $ipmi_oem = can_run('ipmi-oem');
    if (!$ipmi_oem) {
        plugin_log(LOG_ERR, "$plugin_name: can't find ipmi-oem");
        return 0;
    }

    return 1;
}

sub intel_ipmi_power_config {
    my $c = shift;
    plugin_log(LOG_ERR, "$plugin_name: in config hook");
    foreach my $item (@{$c->{children}}) {
        my $key = lc $item->{key};
        my $value = $item->{values};
        if ($key eq 'chassis') {
            $chassis_name = $value;
        } 
        else {
            plugin_log(LOG_ERR, "$plugin_name: unknown config key $key");
        }
    }
    return 0;
}

sub intel_ipmi_power_read {

    if (!$chassis_name) {
        plugin_log(LOG_ERR, "$plugin_name: no chassis name");
        return 0;
    }

    foreach my $chassis (@$chassis_name) {
        #plugin_log(LOG_INFO, "$plugin_name: doing $chassis");
        __get_ipmi_one_chassis($chassis);
    }

    return 1;
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

    if (!$res) {
        plugin_log(LOG_ERR, "$plugin_name: ipmi-oem failed: $!: $res");
        #return 0;
    }
        
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
        plugin_log(LOG_ERR, "$plugin_name: got $node_count, wanted $expected_nodes nodes");
        return 1;
    }

    my $current_power = $summary->{'Current Power'};

    #plugin_log(LOG_INFO, "$plugin_name: $chassis_name: $current_power watts");

    # send a value list to collectd. set the hostname to the current chassis we
    # are grabbing data for
    my $vl = {};
    $vl->{host} = $chassis_name;
    $vl->{plugin} = 'ipmi_intel_power';
    $vl->{type} = 'power',
    $vl->{type_instance} = 'current_power',
    $vl->{values} = [ $current_power ],
    plugin_dispatch_values($vl);

}

1;

