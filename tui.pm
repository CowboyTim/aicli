package tui;
# Drawing on the terminal where we want it, not just at the end of stdout.
#
# Two ways to show the status:
#
#   bar   a footer of two lines at the bottom of the terminal that stays
#         there. The terminal is told to scroll only the lines above it (a
#         scroll region), so everything else, the conversation, the prompt of
#         readline, goes on as before, above the footer. The footer is drawn
#         at its place with the cursor saved and put back.
#           line 1: what is going on (items: "waiting for model", "bash 12s",
#                   "agent 2: thinking"), with a spinner
#           line 2: what there is to know (info: model, tokens, context,
#                   speed, ...)
#   line  one line at the cursor, wiped before anything else is printed. For
#         terminals whose size is not known, and for one request (-p).
#
# Items come and go (set/unset), info stays until it is replaced (info).
# Both can be a text or a sub that gives the text when it is drawn. tick() is
# called from the event loop and animates, clear() is called before something
# is printed. at() draws a text anywhere.
#
# UTF-8 and escape sequences (ECMA-48 / VT100), no curses, no other module.

use strict; use warnings;

use Time::HiRes ();

my @SPINNER = map {chr} 0x280B, 0x2819, 0x2839, 0x2838, 0x283C, 0x2834, 0x2826, 0x2827, 0x2807, 0x280F;
my $SEP      = ' '.chr(0x2502).' '; # │
my $ELLIPSIS = chr(0x2026);         # …
my $TIOCGWINSZ = 0x5413;            # ask the terminal for its size (Linux)

sub new {
    my ($class, %o) = @_;
    my $fh = $o{fh} // \*STDOUT;
    my $self = bless {
        fh       => $fh,
        items    => {},
        order    => [],
        info     => {},
        info_order => [],
        frame    => 0,
        drawn    => 0,
        last     => 0,
        dirty    => 0,
        opened   => 0,           # the footer is on the screen
        footer   => 2,           # its lines
        width    => $o{width},   # fixed size, else the terminal is asked
        rows     => $o{rows},
        interval => $o{interval} // 0.1,
        color    => $o{color} // "\033[0;36m",
        dim      => "\033[0;2m",
        reset    => "\033[0m",
    }, $class;
    my $want = lc($o{mode} // $::ORIG_ENV{AI_STATUS} // 'bar');
    $self->{enabled} = $o{enabled} // (
        (-t $fh
            and ($::ORIG_ENV{TERM} // $ENV{TERM} // 'dumb') ne 'dumb'
            and $want !~ m/^(?:0|off|no|none)$/) ? 1 : 0);
    $self->{mode} = $want eq 'line' ? 'line' : 'bar'; # what is wanted, see open()
    return $self;
}

sub enabled {
    return $_[0]{enabled};
}

# true while the footer is on the screen
sub bar {
    return $_[0]{opened} ? 1 : 0;
}

# (rows, columns) of the terminal, () when that is not known
sub size {
    my ($self) = @_;
    return ($self->{rows}, $self->{width}) if $self->{rows} and $self->{width};
    my $buf = pack('S4', 0, 0, 0, 0);
    my ($rows, $cols) = eval {ioctl($self->{fh}, $TIOCGWINSZ, $buf) ? unpack('S2', $buf) : ()};
    ($rows, $cols) = eval {$::T->get_screen_size()} if !$rows and $::T;
    $rows ||= $::ORIG_ENV{LINES};
    $cols ||= $::ORIG_ENV{COLUMNS};
    return unless $rows and $cols;
    return ($rows, $cols);
}

sub width {
    my ($self) = @_;
    return $self->{width} if $self->{width};
    return $self->{cols} if $self->{opened};
    return ($self->size())[1] || $::ORIG_ENV{COLUMNS} || $ENV{COLUMNS} || 80;
}

#------------------------------------------------------------------------------
# what to show

# show an item: $text is a string, or a sub that returns the current text
sub set {
    my ($self, $key, $text) = @_;
    push @{$self->{order}}, $key unless exists $self->{items}{$key};
    $self->{items}{$key} = {text => $text, since => $self->{items}{$key}{since} // Time::HiRes::time()};
    $self->{dirty} = 1;
    return;
}

sub unset {
    my ($self, $key) = @_;
    return unless delete $self->{items}{$key};
    @{$self->{order}} = grep {$_ ne $key} @{$self->{order}};
    $self->{dirty} = 1;
    if($self->{opened}){
        $self->draw(); # the footer shows that it is over
    } elsif(!@{$self->{order}}){
        $self->clear();
    }
    return;
}

# a piece of the info line: a text, a sub, or undef to take it away. The
# pieces are shown in the order they first came.
sub info {
    my ($self, $key, $text) = @_;
    if(!defined $text){
        return unless exists $self->{info}{$key};
        delete $self->{info}{$key};
        @{$self->{info_order}} = grep {$_ ne $key} @{$self->{info_order}};
    } else {
        push @{$self->{info_order}}, $key unless exists $self->{info}{$key};
        $self->{info}{$key} = $text;
    }
    $self->{dirty} = 1;
    return;
}

sub _elapsed {
    my ($s) = @_;
    return '' if $s < 1;
    return sprintf(" %ds", $s) if $s < 60;
    return sprintf(" %dm%02ds", $s / 60, $s % 60);
}

sub _text {
    my ($t) = @_;
    $t = $t->() if ref($t) eq 'CODE';
    $t //= '';
    utf8::decode($t) unless utf8::is_utf8($t);
    $t =~ s/\s+/ /g;
    return $t;
}

sub _fit {
    my ($self, $line) = @_;
    my $max = $self->width() - 1;
    $line = substr($line, 0, $max - 1).$ELLIPSIS if $max > 1 and length($line) > $max;
    return $line;
}

# the items as one line of text (characters, no escapes), cut to the width
sub line {
    my ($self) = @_;
    my $now = Time::HiRes::time();
    my @parts = map {
        my $i = $self->{items}{$_};
        _text($i->{text})._elapsed($now - $i->{since});
    } @{$self->{order}};
    return $self->_fit($SPINNER[$self->{frame} % @SPINNER].' '.join($SEP, @parts));
}

# the info as one line of text
sub info_line {
    my ($self) = @_;
    return $self->_fit(join($SEP, grep {length} map {_text($self->{info}{$_})} @{$self->{info_order}}));
}

#------------------------------------------------------------------------------
# drawing

sub _out {
    my ($self, $s) = @_;
    utf8::encode($s) if utf8::is_utf8($s);
    my $fh = $self->{fh};
    my $old = select($fh); local $| = 1; select($old);
    print {$fh} $s;
    return;
}

# a text at a place of the screen (row and column from 1), the cursor stays
# where it is
sub at {
    my ($self, $row, $col, $text) = @_;
    return unless $self->{enabled};
    $self->_out("\0337\033[${row};${col}H".$text."\0338");
    return;
}

# Put the footer on the screen: the lines above it become the part that
# scrolls. Returns true when that was done; false when it is not wanted or
# the size of the terminal is not known, the status is one line then.
sub open {
    my ($self) = @_;
    return 0 unless $self->{enabled} and $self->{mode} eq 'bar';
    return 1 if $self->{opened};
    my ($rows, $cols) = $self->size();
    return 0 unless $rows and $rows >= $self->{footer} + 5 and $cols >= 20;
    my $n = $self->{footer};
    # make room below the cursor, go back up, and fence the footer off;
    # setting the region moves the cursor, so it is saved around it
    $self->_out(("\n" x $n)."\033[${n}A"."\0337"."\033[1;".($rows - $n)."r"."\0338");
    @{$self}{qw(opened rows_now cols)} = (1, $rows, $cols);
    $self->draw();
    return 1;
}

# take the footer away again, the whole screen scrolls as before
sub close {
    my ($self) = @_;
    return unless $self->{opened};
    my $rows = $self->{rows_now};
    $self->_out("\0337"."\033[r"
        .join('', map {"\033[".($rows - $_).";1H\033[2K"} 0 .. $self->{footer} - 1)
        ."\0338");
    $self->{opened} = 0;
    return;
}

# the terminal got another size: the footer moves to the new bottom
sub resize {
    my ($self) = @_;
    return unless $self->{opened};
    my ($rows, $cols) = $self->size();
    return if !$rows or ($rows == $self->{rows_now} and $cols == $self->{cols});
    if($rows < $self->{footer} + 5 or $cols < 20){
        $self->close(); # too small for a footer
        return;
    }
    my $n = $self->{footer};
    $self->_out("\0337"."\033[1;".($rows - $n)."r"."\0338");
    @{$self}{qw(rows_now cols)} = ($rows, $cols);
    $self->draw();
    return;
}

sub draw {
    my ($self) = @_;
    return unless $self->{enabled};
    if($self->{opened}){
        my $rows = $self->{rows_now};
        my $items = @{$self->{order}} ? $self->line() : '';
        $self->_out("\0337"
            ."\033[".($rows - 1).";1H\033[2K".$self->{color}.$items.$self->{reset}
            ."\033[".$rows.";1H\033[2K".$self->{dim}.$self->info_line().$self->{reset}
            ."\0338");
    } else {
        return unless @{$self->{order}};
        $self->_out("\r\033[2K".$self->{color}.$self->line().$self->{reset});
        $self->{drawn} = 1;
    }
    $self->{dirty} = 0;
    $self->{last}  = Time::HiRes::time();
    return;
}

# Call this before printing anything else. One line: it is wiped, or it would
# end up in the middle of the text. Footer: nothing is in the way, it is
# brought up to date.
sub clear {
    my ($self) = @_;
    if($self->{opened}){
        $self->draw() if $self->{dirty};
        return;
    }
    return unless $self->{drawn};
    $self->_out("\r\033[2K");
    $self->{drawn} = 0;
    return;
}

# from the event loop: animate
sub tick {
    my ($self) = @_;
    return unless $self->{enabled};
    if(!$self->{opened}){
        return $self->clear() unless @{$self->{order}};
    } elsif(!@{$self->{order}} and !$self->{dirty}){
        return; # nothing moves
    }
    return if Time::HiRes::time() - $self->{last} < $self->{interval};
    $self->{frame}++;
    $self->draw();
    return;
}

1;
