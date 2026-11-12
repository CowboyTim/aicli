package md;
# Markdown in the answer, drawn for the terminal: headings, bold, italic,
# strikethrough, code (spans and blocks), lists, quotes, rules, links and
# tables. Colors and glyphs from tui.pm, escapes only, no module.
#
# The answer streams in, so this works line by line: a line is drawn when it
# is complete, a table when the table is over, what is left at the end by
# flush(). Only what models write is handled; anything else is shown as it is.

use strict; use warnings;

use tui ();

my $RESET  = "\033[0m";
my $CODE   = "\033[38;5;180m"; # inline code: a muted tan
my $FENCE  = "\033[0;36m";     # code blocks: cyan
my $HEAD   = "\033[38;5;33;1m";# headings: bold blue
my $DIM    = "\033[2m";

# base: the color the answer is printed in, it is taken up again after every
# styled part of a line
sub new {
    my ($class, %o) = @_;
    return bless {
        base  => $o{base} // '',
        buf   => '',   # the part of a line that is not complete
        fence => 0,    # inside a code block
        table => [],   # the rows of the table being read
    }, $class;
}

# the text of the answer so far, drawn, for the lines that are complete
sub feed {
    my ($self, $text) = @_;
    $self->{buf} .= $text // '';
    my $out = '';
    while($self->{buf} =~ s/\A(.*?)\n//s){
        $out .= $self->_line($1);
    }
    return $out;
}

# what is left at the end: the last line, a table that is still open
sub flush {
    my ($self) = @_;
    my $out = '';
    if(length $self->{buf}){
        my $last = $self->{buf};
        $self->{buf} = '';
        $out .= $self->_line($last);
    }
    $out .= $self->_table_text();
    return $out;
}

# one line (no newline) drawn, with its newline; '' while it is a table row
sub _line {
    my ($self, $l) = @_;
    $l =~ s/\r\z//;
    if($self->{fence}){
        if($l =~ m/^\s*```\s*$/){
            $self->{fence} = 0;
            return $DIM."```".$RESET."\n";
        }
        return $FENCE.$l.$RESET."\n";
    }
    if($l =~ m/^\s*```(.*)$/){
        my $lang = $1 =~ s/^\s+|\s+$//gr;
        $self->{fence} = 1;
        return $self->_table_text().$DIM."```$lang".$RESET."\n";
    }
    if($l =~ m/^\s*\|.*\|\s*$/){
        push @{$self->{table}}, $l;
        return '';
    }
    return $self->_table_text().$self->{base}.$self->_style($l).$RESET."\n";
}

# the parts of a line that are block elements; the rest is inline
sub _style {
    my ($self, $l) = @_;
    my $b = $self->{base};
    if($l =~ m/^(#{1,6})\s+(.*?)\s*#*\s*$/){
        return $HEAD.$self->_inline($2).$RESET.$b;
    }
    if($l =~ m/^\s*([-*_])(?:\s*\1){2,}\s*$/){
        return $DIM.(tui::glyph('rule') x 40).$RESET.$b;
    }
    if($l =~ m/^(\s*)[-*+]\s+(.*)$/){
        return $1.tui::glyph('bullet').' '.$self->_inline($2);
    }
    if($l =~ m/^(\s*)(\d+[.)])\s+(.*)$/){
        return $1.$2.' '.$self->_inline($3);
    }
    if($l =~ m/^\s*>\s?(.*)$/){
        return $DIM.tui::glyph('bar').' '.$RESET.$b.$self->_inline($1);
    }
    return $self->_inline($l);
}

# inline: code spans first, then the emphasis of the rest
sub _inline {
    my ($self, $s) = @_;
    my $b = $self->{base};
    my @parts = split /(`[^`\n]+`)/, $s;
    return join '', map {
        if(m/^`([^`]+)`$/){
            $CODE.$1.$RESET.$b;
        } else {
            _emphasis($_, $b);
        }
    } @parts;
}

sub _emphasis {
    my ($s, $b) = @_;
    $s =~ s/\*\*(?=\S)(.+?)(?<=\S)\*\*/\033[1m$1\033[22m/g;
    $s =~ s/__(?=\S)(.+?)(?<=\S)__/\033[1m$1\033[22m/g;
    $s =~ s/(?<![\w*])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![\w*])/\033[3m$1\033[23m/g;
    $s =~ s/~~(?=\S)(.+?)(?<=\S)~~/\033[9m$1\033[29m/g;
    $s =~ s/\[([^\]\n]+)\]\(([^)\s]+)\)/\033[4m$1\033[24m ${DIM}($2)\033[22m/g;
    return $s;
}

# the rows read so far, drawn as a table with aligned columns; '' if none
sub _table_text {
    my ($self) = @_;
    my @rows = @{$self->{table}};
    $self->{table} = [];
    return '' unless @rows;
    my @cells = map {
        my $r = $_;
        $r =~ s/^\s*\|//;
        $r =~ s/\|\s*$//;
        [map {my $c = $_; $c =~ s/^\s+|\s+$//g; $c} split /\|/, $r, -1];
    } @rows;
    my $is_sep = sub {
        my $row = shift;
        return !grep {!m/^:?-+:?$/} @$row;
    };
    my ($head, @body) = @cells;
    my @show = grep {!$is_sep->($_)} @cells;
    return '' unless @show;
    my $cols = 0;
    $cols = @$_ > $cols ? scalar(@$_) : $cols for @show;
    my @w = (0) x $cols;
    my $plain = sub { (my $s = shift) =~ s/\e\[[0-9;]*m//g; $s };
    for my $row (@show){
        for my $i (0 .. $cols - 1){
            my $c = $row->[$i] // '';
            my $n = tui::_cols($plain->(_inline_plain($c)));
            $w[$i] = $n if $n > $w[$i];
        }
    }
    my $b = $self->{base};
    my $out = '';
    my $first = 1;
    for my $row (@show){
        my $line = join(tui::glyph('sep'), map {
            my $i = $_;
            my $c = $self->_inline($row->[$i] // '');
            my $pad = $w[$i] - tui::_cols($plain->($c));
            $c.(' ' x $pad);
        } 0 .. $cols - 1);
        if($first){
            $out .= $b."\033[1m".$line.$RESET.$b."\n";
            $out .= $DIM.(tui::glyph('rule') x tui::_cols($plain->($line))).$RESET."\n";
            $first = 0;
        } else {
            $out .= $b.$line.$RESET."\n";
        }
    }
    return $out;
}

# a cell without its escapes (for the width)
sub _inline_plain {
    my ($c) = @_;
    $c =~ s/`([^`]+)`/$1/g;
    $c =~ s/\*\*(.+?)\*\*/$1/g;
    $c =~ s/__(.+?)__/$1/g;
    $c =~ s/\*(.+?)\*/$1/g;
    $c =~ s/\[([^\]]+)\]\([^)]+\)/$1/g;
    return $c;
}

1;
