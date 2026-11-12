package tui;
# A status line for the terminal: named items ("model", "agent 1", ...) are
# shown on one line with a spinner and how long they are busy. It is drawn
# from the event loop (tick) and wiped before anything else is printed
# (clear), so it never ends up in the scrollback. UTF-8 and color escapes, no
# curses.

use strict; use warnings;

use Time::HiRes ();

my @SPINNER = map {chr} 0x280B, 0x2819, 0x2839, 0x2838, 0x283C, 0x2834, 0x2826, 0x2827, 0x2807, 0x280F;
my $SEP      = ' '.chr(0x2502).' '; # │
my $ELLIPSIS = chr(0x2026);         # …

sub new {
    my ($class, %o) = @_;
    my $fh = $o{fh} // \*STDOUT;
    my $self = bless {
        fh       => $fh,
        items    => {},
        order    => [],
        frame    => 0,
        drawn    => 0,
        last     => 0,
        width    => $o{width},
        interval => $o{interval} // 0.1,
        color    => $o{color} // "\033[0;36m",
        reset    => "\033[0m",
    }, $class;
    $self->{enabled} = $o{enabled} // (
        (-t $fh
            and ($::ORIG_ENV{TERM} // $ENV{TERM} // 'dumb') ne 'dumb'
            and ($::ORIG_ENV{AI_STATUS} // 1)) ? 1 : 0);
    return $self;
}

sub enabled {
    return $_[0]{enabled};
}

# show an item: $text is a string, or a sub that returns the current text
sub set {
    my ($self, $key, $text) = @_;
    push @{$self->{order}}, $key unless exists $self->{items}{$key};
    $self->{items}{$key} = {text => $text, since => $self->{items}{$key}{since} // Time::HiRes::time()};
    return;
}

sub unset {
    my ($self, $key) = @_;
    return unless delete $self->{items}{$key};
    @{$self->{order}} = grep {$_ ne $key} @{$self->{order}};
    $self->clear() unless @{$self->{order}};
    return;
}

sub width {
    my ($self) = @_;
    return $self->{width} if $self->{width};
    my $w = $::T ? eval {($::T->get_screen_size())[1]} : undef;
    $w ||= $::ORIG_ENV{COLUMNS} || $ENV{COLUMNS} || 80;
    return $w;
}

sub _elapsed {
    my ($s) = @_;
    return '' if $s < 1;
    return sprintf(" %ds", $s) if $s < 60;
    return sprintf(" %dm%02ds", $s / 60, $s % 60);
}

# the status line as text (characters, no escapes), cut to the terminal width
sub line {
    my ($self) = @_;
    my $now = Time::HiRes::time();
    my @parts = map {
        my $i = $self->{items}{$_};
        my $t = ref($i->{text}) eq 'CODE' ? $i->{text}->() : $i->{text};
        $t //= '';
        utf8::decode($t) unless utf8::is_utf8($t);
        $t =~ s/\s+/ /g;
        $t._elapsed($now - $i->{since});
    } @{$self->{order}};
    my $line = $SPINNER[$self->{frame} % @SPINNER].' '.join($SEP, @parts);
    my $max = $self->width() - 1;
    $line = substr($line, 0, $max - 1).$ELLIPSIS if $max > 1 and length($line) > $max;
    return $line;
}

sub _out {
    my ($self, $s) = @_;
    utf8::encode($s) if utf8::is_utf8($s);
    my $fh = $self->{fh};
    my $old = select($fh); local $| = 1; select($old);
    print {$fh} $s;
    return;
}

sub draw {
    my ($self) = @_;
    return unless $self->{enabled} and @{$self->{order}};
    $self->_out("\r\033[2K".$self->{color}.$self->line().$self->{reset});
    $self->{drawn} = 1;
    $self->{last}  = Time::HiRes::time();
    return;
}

# wipe the status line: call this before printing anything else
sub clear {
    my ($self) = @_;
    return unless $self->{drawn};
    $self->_out("\r\033[2K");
    $self->{drawn} = 0;
    return;
}

# from the event loop: animate
sub tick {
    my ($self) = @_;
    return unless $self->{enabled};
    return $self->clear() unless @{$self->{order}};
    return if Time::HiRes::time() - $self->{last} < $self->{interval};
    $self->{frame}++;
    $self->draw();
    return;
}

1;
