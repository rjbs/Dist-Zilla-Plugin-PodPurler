package Dist::Zilla::Plugin::PodPurler;
# ABSTRACT: like PodWeaver, but more erratic and amateurish
use Moose;
use Moose::Autobox;
use List::MoreUtils qw(any);
with 'Dist::Zilla::Role::FileMunger';

use namespace::autoclean;

use Pod::Elemental;
use Pod::Elemental::Selectors -all;
use Pod::Elemental::Transformer::Pod5;
use Pod::Elemental::Transformer::Nester;
use Pod::Elemental::Transformer::Gatherer;

=head1 WARNING

This code is really, really sketchy.  It's crude and brutal and will probably
break whatever it is you were trying to do.

Unlike L<Dist::Zilla::Plugin::PodWeaver|Dist::Zilla::Plugin::PodWeaver>, this
code will not get awesome.  In fact, it's just the old PodWeaver code, spun out
(no pun intended) so that RJBS can use it while he fixes PodWeaver-related
things.

=head1 DESCRIPTION

PodPurler ress, which rips apart your kinda-POD and reconstructs it as boring
old real POD.

=cut

sub munge_file {
  my ($self, $file) = @_;

  return $self->munge_pod($file)
    if $file->name =~ /\.(?:pm|pod)$/i
    and ($file->name !~ m{/} or $file->name =~ m{^lib/});

  return;
}

{
  package Dist::Zilla::Plugin::PodPurler::Eventual;
  our @ISA = 'Pod::Eventual';
  sub new {
    my ($class) = @_;
    require Pod::Eventual;
    bless [] => $class;
  }

  sub handle_event { push @{$_[0]}, $_[1] }
  sub events { @{ $_[0] } }
  sub read_string { my $self = shift; $self->SUPER::read_string(@_); $self }
}

sub munge_pod {
  my ($self, $file) = @_;

  require PPI;
  my $content = $file->content;
  my $doc = PPI::Document->new(\$content);
  my @pod_tokens = map {"$_"} @{ $doc->find('PPI::Token::Pod') || [] };
  $doc->prune('PPI::Token::Pod');

  my $pe = 'Dist::Zilla::Plugin::PodPurler::Eventual';

  if ($pe->new->read_string("$doc")->events) {
    $self->log(
      sprintf "can't invoke %s on %s: there is POD inside string literals",
        $self->plugin_name, $file->name
    );
    return;
  }

  my $pod_str = join "\n", @pod_tokens;
  my $document = Pod::Elemental->read_string($pod_str);
  Pod::Elemental::Transformer::Pod5->new->transform_node($document);

  my $nester = Pod::Elemental::Transformer::Nester->new({
    top_selector => s_command([ qw(head1 method attr) ]),
    content_selectors => [
      s_flat,
      s_command( [ qw(head2 head3 head4 over item back) ]),
    ],
  });

  $nester->transform_node($document);

  my $m_gatherer = Pod::Elemental::Transformer::Gatherer->new({
    gather_selector => s_command([ qw(method) ]),
    container       => Pod::Elemental::Element::Nested->new({
      command => 'head1',
      content => "METHODS\n",
    }),
  });

  $m_gatherer->transform_node($document);

  $m_gatherer->container->children->grep(s_command('method'))->each_value(sub {
    $_->command('head2');
  });

  my $attr_gatherer = Pod::Elemental::Transformer::Gatherer->new({
    gather_selector => s_command([ qw(attr) ]),
    container       => Pod::Elemental::Element::Nested->new({
      command => 'head1',
      content => "ATTRIBUTES\n",
    }),
  });

  $attr_gatherer->transform_node($document);

  $attr_gatherer->container->children->grep(s_command('attr'))->each_value(sub {
    $_->command('head2');
  });

  unless (
    $document->children->grep(sub {
      s_command('head1', $_) and $_->content eq "VERSION\n"
    })->length
  ) {
    my $version_section = Pod::Elemental::Element::Nested->new({
      command  => 'head1',
      content  => "VERSION\n",
      children => [
        Pod::Elemental::Element::Pod5::Ordinary->new({
          content => sprintf "version %s\n", $self->zilla->version,
        }),
      ],
    });

    $document->children->unshift, $version_section;
  }

  unless (
    $document->children->grep(sub {
      s_command('head1', $_) and $_->content eq "NAME\n"
    })->length
  ) {
    Carp::croak "couldn't find package declaration in " . $file->name
      unless my $pkg_node = $doc->find_first('PPI::Statement::Package');

    my $package = $pkg_node->namespace;

    $self->log("couldn't find abstract in " . $file->name)
      unless my ($abstract) = $doc =~ /^\s*#+\s*ABSTRACT:\s*(.+)$/m;

    my $name = $package;
    $name .= " - $abstract" if $abstract;

    my $name_section = Pod::Elemental::Element::Nested->new({
      command  => 'head1',
      content  => "NAME\n",
      children => [
        Pod::Elemental::Element::Pod5::Ordinary->new({
          content => "$name\n",
        }),
      ],
    });

    $document->children->unshift, $name_section;
  }

  unless (
    $document->children->grep(sub {
      s_command('head1', $_) and $_->content =~ /\AAUTHORS?\n\z/
    })->length
  ) {
    my @authors = $self->zilla->authors->flatten;
    my $name = @authors > 1 ? 'AUTHORS' : 'AUTHOR';

    my $author_section = Pod::Elemental::Element::Nested->new({
      command  => 'head1',
      content  => "$name\n",
      children => [
        Pod::Elemental::Element::Pod5::Ordinary->new({
          content => join("\n", @authors) . "\n"
        }),
      ],
    });

    $document->children->unshift, $author_section;
  }

  unless (
    $document->children->grep(sub {
      s_command('head1', $_) and $_->content =~ /\A(?:COPYRIGHT|LICENSE)\n\z/
    })->length
  ) {
    my $legal_section = Pod::Elemental::Element::Nested->new({
      command  => 'head1',
      content  => "COPYRIGHT AND LICENSE\n",
      children => [
        Pod::Elemental::Element::Pod5::Ordinary->new({
          content => $self->zilla->liense->notice
        }),
      ],
    });

    $document->children->unshift, $legal_section;
  }

  my $newpod = $document->as_pod_string;

  my $end = do {
    my $end_elem = $doc->find('PPI::Statement::Data')
                || $doc->find('PPI::Statement::End');
    join q{}, @{ $end_elem || [] };
  };

  $doc->prune('PPI::Statement::End');
  $doc->prune('PPI::Statement::Data');

  my $docstr = $doc->serialize;

  $content = $end
           ? "$docstr\n\n$newpod\n\n$end"
           : "$docstr\n__END__\n$newpod\n";

  $file->content($content);
}

__PACKAGE__->meta->make_immutable;
no Moose;
1;
