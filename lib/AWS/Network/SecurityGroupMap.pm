package AWS::Network::SecurityGroupMap;
  use feature 'postderef';
  use Moose;
  use GraphViz2;
  use Paws;

  has graphviz => (
    is => 'ro',
    lazy => 1,
    default => sub {
      my $self = shift;
      GraphViz2->new(
        global => { directed => 1 },
        graph => {
          label => $self->title,
          layout => 'twopi',
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
    isa => 'HashRef',
    default => sub { {} },
    traits => [ 'Hash' ],
    handles => {
      objects => 'values',
      add_object => 'set',
    }
  );
  has _listens_to => (
    is => 'ro',
    isa => 'HashRef',
    default => sub { {} }
  );
  has _is_in_set => (
    is => 'ro',
    isa => 'HashRef',
    default => sub { {} }
  );

  sub is_in_set {
    my ($self, $object, $set) = @_;
    $self->_is_in_set->{ $set }->{ $object } = 1;
  }

  sub in_set {
    my ($self, $set) = @_;
    keys %{ $self->_is_in_set->{ $set } };
  }

  sub get_who_listens {
    my $self = shift;
    return keys %{ $self->_listens_to };
  }

  sub get_talks_to {
    my ($self, $o1) = @_;
    return keys %{ $self->_listens_to->{ $o1 } };
  }

  sub set_listens_to {
    my ($self, $o1, $o2, $port) = @_;

    #$self->_objects->{ $o1 } = $o1;
    #$self->_objects->{ $o2 } = $o2;

    $self->_listens_to->{ $o1 } = {} if (not defined $self->_listens_to->{ $o1 });
    $self->_listens_to->{ $o1 }->{ $o2 } = [] if (not defined $self->_listens_to->{ $o1 }->{ $o2 });
    push @{ $self->_listens_to->{ $o1 }->{ $o2 } }, $port;
  }

  sub _scan_instances {
    my $self = shift;

    $self->aws->service('EC2')->DescribeAllInstances(sub {
      my $rsv = shift;
      foreach my $instance ($rsv->Instances->@*) {
        $self->add_object($instance->InstanceId, { name => $instance->InstanceId, type => 'i' });
        foreach my $sg ($instance->SecurityGroups->@*) {
          $self->is_in_set($instance->InstanceId, $sg->GroupId);
        }
      }
    });
  }

  sub _scan_securitygroups {
    my $self = shift;

    my $sgs = $self->aws->service('EC2')->DescribeSecurityGroups;
    foreach my $sg ($sgs->SecurityGroups->@*) {
      foreach my $ip_perm ($sg->IpPermissions->@*){
        my $port;
        if ($ip_perm->IpProtocol == -1) {
          $port = 'icmp';
        } else {
          if ($ip_perm->FromPort == $ip_perm->ToPort) {
            $port = $ip_perm->FromPort;
          } else {
            $port = $ip_perm->FromPort . '-' . $ip_perm->ToPort;
          }
        }

        foreach my $ip_r ($ip_perm->IpRanges->@*) {
          $self->set_listens_to($sg->GroupId, $ip_r->CidrIp, $port);
        }
        foreach my $ip_r ($ip_perm->Ipv6Ranges->@*) {
          $self->set_listens_to($sg->GroupId, $ip_r->CidrIpv6, $port);
        }
        foreach my $ip_p ($ip_perm->PrefixListIds->@*) {
          die "Don't know how to handle PrefixLists yet";
        }
        foreach my $ip_p ($ip_perm->UserIdGroupPairs->@*) {
          $self->set_listens_to($sg->GroupId, $ip_p->GroupId, $port);
        }
      }
    }
  }

  sub run {
    my ($self) = @_;

    $self->_scan_instances;
    #$self->_scan_autoscalinggroups;
    #$self->_scan_loadbalancers;
    #$self->_scan_rds;
    #$self->_scan_redshift;

    $self->_scan_securitygroups;

use Data::Dumper;
print Dumper($self->_objects);
print Dumper($self->_is_in_set);
print Dumper($self->_listens_to);

    foreach my $object ($self->objects) {
      my %extra = ();
      $extra{ shape } = 'box';
      $extra{ labelloc } = 'b';

      $self->graphviz->add_node(name => $object->{name}, %extra);
    }

    foreach my $listener ($self->get_who_listens) {
      # listeners are names of security groups. There can be lots of things in an SG
      my @things_in_sg = $self->in_set($listener);
      @things_in_sg = ("Things in $listener") if (not @things_in_sg);

      foreach my $thing_in_sg (@things_in_sg) {
        foreach my $talks_to ($self->get_talks_to($listener)){
          my @things_in_sg2 = $self->in_set($talks_to);
          @things_in_sg2 = ("Things in $talks_to") if (not @things_in_sg2);

          foreach my $talked_to (@things_in_sg2){
            #$self->graphviz->add_edge(from => $talked_to, to => $thing_in_sg);
            $self->graphviz->add_edge(from => $thing_in_sg, to => $talked_to);
          }
        }
      }
    }

    $self->graphviz->run(format => 'dot', output_file => 'graph.dot');
    $self->graphviz->run(format => 'svg', output_file => 'graph.svg');
    $self->graphviz->run(format => 'png', output_file => 'graph.png');
  }

1;
