#!/usr/bin/env perl

use strict;
use warnings;
use AWS::Network::SecurityGroupMap;

my $map = AWS::Network::SecurityGroupMap->new(
  region => 'x',
);

my $sg1 = $map->register_sg(name => 'sg-1', label => 'ELBToWorld');
$sg1->set_listens_to('0.0.0.0/0', 443);
my $sg2 = $map->register_sg(name => 'sg-2', label => 'InstancesToELB');
$sg2->set_listens_to('sg-1', 80);
$sg2->set_listens_to('1.1.1.1/32', 22);
$sg2->set_listens_to('1.1.1.1/32', 80);
my $sg3 = $map->register_sg(name => 'sg-3', label => 'RDS');
$sg3->set_listens_to('sg-2', 3306);


$map->add_object(name => 'elb-XXX', type => 'elb');
$map->sg_holds('sg-1', 'elb-XXX');

foreach my $i ('i-11111111','i-11111112','i-11111113','i-11111114') {
  $map->add_object(name => $i, type => 'i');
  $map->sg_holds('sg-2', $i);
}

$map->add_object(name => 'RDSXYZ', type => 'rds');
$map->sg_holds('sg-3', 'RDSXYZ');

$map->draw;
