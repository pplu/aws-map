package AWS::Map::Object;
  use Moose;
  has type => (is => 'ro', isa => 'Str', required => 1);
  has name => (is => 'ro', isa => 'Str', required => 1);
  has label => (is => 'ro', isa => 'Str');

package AWS::Map::SG;
  use Moose;
  has name => (is => 'ro', isa => 'Str', required => 1);
  has label => (is => 'ro', isa => 'Str', required => 1);
  has listens_to => (is => 'ro', isa => 'HashRef', default => sub { {} });

  sub set_listens_to {
    my ($self, $o2, $port) = @_;

    $self->listens_to->{ $o2 } = [] if (not defined $self->listens_to->{ $o2 });
    push @{ $self->listens_to->{ $o2 } }, $port;
  }

package AWS::Network::SecurityGroupMap;
  use feature 'postderef';
  use Moose;
  use GraphViz2;
  use Paws;
  use AWS::Map::Object;

  has graphviz => (
    is => 'ro',
    lazy => 1,
    default => sub {
      my $self = shift;
      GraphViz2->new(
        global => { directed => 1, ranksep => 5 },
        graph => {
          label => $self->title,
          #layout => 'twopi',
        },
      );
    }
  );

  has aws => (is => 'ro', isa => 'Paws', lazy => 1, default => sub {
    my $self = shift;
    Paws->new(config => {
      region => $self->region,
    });
  });

  has region => (is => 'ro', isa => 'Str', required => 1);
  has title => (is => 'ro', isa => 'Str', lazy => 1, default => sub {
    my $self = shift;
    "AWS " . $self->region . " " . scalar(localtime);  
  });
  
  has _objects => (
    is => 'ro',
    isa => 'HashRef[AWS::Map::Object]',
    default => sub { {} },
    traits => [ 'Hash' ],
    handles => {
      objects => 'values',
    }
  );

  sub add_object {
    my ($self, %args) = @_;
    my $o = AWS::Map::Object->new(%args);
    $self->_objects->{ $o->name } = $o;
  }

  has _sg => (
    is => 'ro',
    isa => 'HashRef[AWS::Map::SG]',
    default => sub { {} }
  );

  # holds what objects an SG contains
  has _contains => (
    is => 'ro',
    isa => 'HashRef',
    default => sub { {} }
  );

  sub sg_holds {
    my ($self, $sg, $object) = @_;
    $self->_contains->{ $sg }->{ $object } = 1;
  }

  sub get_objects_in_sg {
    my ($self, $sg) = @_;
    keys %{ $self->_contains->{ $sg } };
  }

  sub get_who_listens {
    my $self = shift;
    return keys %{ $self->_sg };
  }

  sub get_listens_to {
    my ($self, $o1) = @_;
    return keys %{ $self->_sg->{ $o1 }->listens_to };
  }

  sub get_listens_on_ports {
    my ($self, $o1, $o2) = @_;
    return @{ $self->_sg->{ $o1 }->listens_to->{ $o2 } };
  }

  sub register_sg {
    my ($self, %params) = @_;
    die "Can't register without a name" if (not defined $params{ name });
    return $self->_sg->{ $params{ name } } = AWS::Map::SG->new(%params);
  }


  sub _scan_elbs {
    my $self = shift;

    $self->aws->service('ELB')->DescribeAllLoadBalancers(sub {
      my $elb = shift;

      $self->add_object(name => $elb->LoadBalancerName, type => 'elb');

      foreach my $sg ($elb->SecurityGroups->@*) {
        $self->sg_holds($sg, $elb->LoadBalancerName);
      }
    });
  }

  sub _scan_elbv2s {
    my $self = shift;

    $self->aws->service('ELBv2')->DescribeAllLoadBalancers(sub {
      my $elb = shift;

      $self->add_object(name => $elb->LoadBalancerName, type => 'alb');

      foreach my $sg ($elb->SecurityGroups->@*) {
        $self->sg_holds($sg, $elb->LoadBalancerName);
      }
    });
  }


  sub _scan_rds {
    my $self = shift;

    $self->aws->service('RDS')->DescribeAllDBInstances(sub {
      my $instance = shift;
      $self->add_object(name => $instance->DBInstanceIdentifier, type => 'rds');

      foreach my $sg ($instance->VpcSecurityGroups->@*) {
        $self->sg_holds($sg->VpcSecurityGroupId, $instance->DBInstanceIdentifier);
      }
    });

    #TODO: DescribeAllDBClusters
  }

  sub _scan_instances {
    my $self = shift;

    $self->aws->service('EC2')->DescribeAllInstances(sub {
      my $rsv = shift;
      foreach my $instance ($rsv->Instances->@*) {
        $self->add_object(name => $instance->InstanceId, type => 'i');

        foreach my $sg ($instance->SecurityGroups->@*) {
          $self->sg_holds($sg->GroupId, $instance->InstanceId);
        }
      }
    });
  }

  sub _scan_securitygroups {
    my $self = shift;

    my $sgs = $self->aws->service('EC2')->DescribeSecurityGroups;
    foreach my $sg ($sgs->SecurityGroups->@*) {
      my $model = $self->register_sg(name => $sg->GroupId, label => $sg->Description);

      foreach my $ip_perm ($sg->IpPermissions->@*){
        my $port;
        if ($ip_perm->IpProtocol eq 'icmp') {
          $port = 'ICMP';
        } else {
          if ($ip_perm->FromPort == $ip_perm->ToPort) {
            $port = $ip_perm->FromPort;
          } else {
            $port = $ip_perm->FromPort . '-' . $ip_perm->ToPort;
          }
          $port .= ' UDP' if ($ip_perm->IpProtocol eq 'udp');
        }

        foreach my $ip_r ($ip_perm->IpRanges->@*) {
          $model->set_listens_to($ip_r->CidrIp, $port);
        }
        foreach my $ip_r ($ip_perm->Ipv6Ranges->@*) {
          $model->set_listens_to($ip_r->CidrIpv6, $port);
        }
        foreach my $ip_p ($ip_perm->PrefixListIds->@*) {
          die "Don't know how to handle PrefixLists yet";
        }
        foreach my $ip_p ($ip_perm->UserIdGroupPairs->@*) {
          $model->set_listens_to($ip_p->GroupId, $port);
        }
      }
    }
  }

  sub run {
    my ($self) = @_;

    $self->_scan_instances;
    #$self->_scan_autoscalinggroups;
    $self->_scan_elbs;
    $self->_scan_elbv2s;
    $self->_scan_rds;
    #$self->_scan_redshift;

    $self->_scan_securitygroups;

use Data::Dumper;
print Dumper($self->_objects);
print Dumper($self->_contains);
print Dumper($self->_listens_to);

    foreach my $object ($self->objects) {
      my %extra = ();
      $extra{ shape } = 'box';
      $extra{ labelloc } = 'b';

      $self->graphviz->add_node(name => $object->{name}, %extra);
    }

    foreach my $listener ($self->get_who_listens) {
      # listeners are names of security groups. There can be lots of things in an SG
      my @things_in_sg = $self->get_objects_in_sg($listener);
      @things_in_sg = ("Things in $listener") if (not @things_in_sg);

      foreach my $thing_in_sg (@things_in_sg) {
        foreach my $listened_to ($self->get_listens_to($listener)){
          my @things_in_sg2 = $self->get_objects_in_sg($listened_to);
          @things_in_sg2 = ("Things in $listened_to") if (not @things_in_sg2);

          foreach my $thing_listened_to (@things_in_sg2){
            my $label = join ', ', $self->get_listens_on_ports($listener, $listened_to);
            $self->graphviz->add_edge(
              from => $thing_listened_to,
              to => $thing_in_sg,
              label => $label,
            );
          }
        }
      }
    }

    $self->graphviz->run(format => 'dot', output_file => 'graph.dot');
    $self->graphviz->run(format => 'svg', output_file => 'graph.svg');
    $self->graphviz->run(format => 'png', output_file => 'graph.png');
  }

1;
