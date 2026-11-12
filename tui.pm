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

# Glyphs. Terminals differ in how wide some characters are (East Asian
# ambiguous ones like the box line and the arrows, emoji), so the footer
# measures what it prints and only uses these where the locale is UTF-8.
# Otherwise (or with AI_GLYPHS=ascii) the ASCII set is used. AI_GLYPHS=unicode
# forces the other.
my %GLYPH = (
    unicode => {
        spinner  => [map {chr} 0x280B, 0x2819, 0x2839, 0x2838, 0x283C, 0x2834, 0x2826, 0x2827, 0x2807, 0x280F],
        sep      => ' '.chr(0x2502).' ', # │
        ellipsis => chr(0x2026),         # …
        up       => chr(0x2191),         # ↑
        down     => chr(0x2193),         # ↓
        sum      => chr(0x3a3),          # Σ
        open     => chr(0x2772),         # ❲
        close    => chr(0x2773),         # ❳
        arrow    => chr(0x25ba),         # ►
        bar      => chr(0x2502),         # │
    },
    ascii => {
        spinner  => [qw(| / - \\)],
        sep      => ' | ',
        ellipsis => '...',
        up       => 'in:',
        down     => 'out:',
        sum      => 'sum:',
        open     => "[",
        close    => "]",
        arrow    => ">",
        bar      => "|",
    },
);
my $TIOCGWINSZ = 0x5413;            # ask the terminal for its size (Linux)

# true when the characters of the glyph set above can be shown
sub unicode_ok {
    my $want = lc($::ORIG_ENV{AI_GLYPHS} // '');
    return 1 if $want eq 'unicode';
    return 0 if $want eq 'ascii';
    my $env = %::ORIG_ENV ? \%::ORIG_ENV : \%ENV;
    my $loc = $env->{LC_ALL} || $env->{LC_CTYPE} || $env->{LANG} || '';
    return $loc =~ m/utf-?8/i ? 1 : 0;
}

# one glyph of the set: glyph('sep'), glyph('spinner') is a list of frames
sub glyph {
    my ($name) = @_;
    my $set = $GLYPH{unicode_ok() ? 'unicode' : 'ascii'};
    return $set->{$name};
}

# How many columns a character takes on the screen. Zero for combining marks
# and joiners, two for the wide East Asian ranges and emoji, one otherwise.
sub _cw {
    my ($o) = @_;
    return 0 if ($o >= 0x300 && $o <= 0x36F) || ($o >= 0x200B && $o <= 0x200F)
        || ($o >= 0xFE00 && $o <= 0xFE0F) || ($o >= 0x20D0 && $o <= 0x20FF);
    return 2 if _emoji($o) || ($o >= 0x1100 && $o <= 0x115F) || ($o >= 0x2E80 && $o <= 0x303E)
        || ($o >= 0x3041 && $o <= 0x33FF) || ($o >= 0x3400 && $o <= 0x4DBF)
        || ($o >= 0x4E00 && $o <= 0x9FFF) || ($o >= 0xA000 && $o <= 0xA4CF)
        || ($o >= 0xAC00 && $o <= 0xD7A3) || ($o >= 0xF900 && $o <= 0xFAFF)
        || ($o >= 0xFE30 && $o <= 0xFE4F) || ($o >= 0xFF00 && $o <= 0xFF60)
        || ($o >= 0xFFE0 && $o <= 0xFFE6) || ($o >= 0x20000 && $o <= 0x3FFFD);
    return 1;
}

# emoji and pictographs: their width differs between terminals (text or emoji
# presentation, joiners), so the footer shows a '?' for them
sub _emoji {
    my ($o) = @_;
    return ($o >= 0x1F000 && $o <= 0x1FAFF) || ($o >= 0x2600 && $o <= 0x27BF)
        || ($o >= 0x2B00 && $o <= 0x2BFF) || ($o >= 0x231A && $o <= 0x231B)
        || ($o >= 0x23E9 && $o <= 0x23FA);
}

# columns of a text (characters, no escapes)
sub _cols {
    my ($s) = @_;
    my $n = 0;
    $n += _cw(ord $_) for split //, $s;
    return $n;
}

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

# the text of an item or info piece, as the footer can show it: one line, no
# zero-width characters, no emoji (they are a '?')
sub _text {
    my ($t) = @_;
    $t = $t->() if ref($t) eq 'CODE';
    $t //= '';
    utf8::decode($t) unless utf8::is_utf8($t);
    $t =~ s/\s+/ /g;
    $t = join('', map {
        my $o = ord $_;
        _cw($o) == 0 ? '' : _emoji($o) ? '?' : $_;
    } split //, $t);
    return $t;
}

# cut a line to the columns there are (one less than the width, so the
# terminal never wraps it), with an ellipsis when something was cut
sub _fit {
    my ($self, $line) = @_;
    my $max = $self->width() - 1;
    return $line if _cols($line) <= $max;
    return substr($line, 0, $max) if $max <= 1;
    my $ellipsis = glyph('ellipsis');
    my $room = $max - _cols($ellipsis);
    my ($cut, $w) = ('', 0);
    for my $c (split //, $line) {
        my $cw = _cw(ord $c);
        last if $w + $cw > $room;
        $cut .= $c;
        $w += $cw;
    }
    return $cut.$ellipsis;
}

# the items as one line of text (characters, no escapes), cut to the width
sub line {
    my ($self) = @_;
    my $now = Time::HiRes::time();
    my @parts = map {
        my $i = $self->{items}{$_};
        _text($i->{text})._elapsed($now - $i->{since});
    } @{$self->{order}};
    my $frames = glyph('spinner');
    return $self->_fit($frames->[$self->{frame} % @$frames].' '.join(glyph('sep'), @parts));
}

# the info as one line of text
sub info_line {
    my ($self) = @_;
    return $self->_fit(join(glyph('sep'), grep {length} map {_text($self->{info}{$_})} @{$self->{info_order}}));
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
