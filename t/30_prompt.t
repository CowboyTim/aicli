#!/usr/bin/perl
use strict; use warnings;

use Test::More;
use Data::Dumper;
use FindBin;
use lib "$FindBin::Bin/..";
local $Data::Dumper::Sortkeys = 1;
no warnings 'once';

$::DEBUG = ($ENV{DEBUG}//"0") == "1"?1:0;

use_ok("ai");

{
    my $p = prompt::coder::prompt();
    is($p, q{

**TOOLS**



TOOLS SYNTAX, for tool 'TOOL':

```
///TOOL_{HEX}+{T1}+{T2}
{{path}}
{T1}
{{content}}
{T2}
TOOL_{HEX}
```
Where {{path}}, {{content}} is substituted by the LLM
TOOL results: [<TOOL_{HEX}> RESULT_d170b4e6bb11cfd550aa
{{result}}
RESULT_d170b4e6bb11cfd550aa]
TOOL errors: [<TOOL_{HEX}> ERROR_9a7893514ebc885c2543
{{error}}
ERROR_9a7893514ebc885c2543]


LIST OF TOOLS:

name: bash
tool: ```
///BASH_7c48+EO_dfd7e6b99d1bf15480fa
{{code}}
EO_dfd7e6b99d1bf15480fa
BASH_7c48
```
description: execute a bash script
properties:
 code:
  description: The bash code to execute
  type: string


name: grep
tool: ```
///GREP_6629+EO_a575a5c230c77d451640+EO_aaddf906cba61ec85a13
{{path}}
EO_a575a5c230c77d451640
{{regex}}
EO_aaddf906cba61ec85a13
GREP_6629
```
description: search file with a pattern using grep unix tool
properties:
 path:
  description: The file path or directory to scan
  type: string
 regex:
  description: The grep pattern
  type: string


name: perl
tool: ```
///PERL_d8d2+EO_929b2e8d61111fac138f
{{code}}
EO_929b2e8d61111fac138f
PERL_d8d2
```
description: execute a perl script
properties:
 code:
  description: The perl code to execute
  type: string


name: read
tool: ```
///READ_c5a3+EO_d0f15b09ea7648f828e7
{{path}}
EO_d0f15b09ea7648f828e7
READ_c5a3
```
description: read a file contents
properties:
 path:
  description: The path to the file
  type: string


name: write
tool: ```
///WRITE_edf5+EO_d0684c052bf3d9c503a8+EO_ecdeef376b1647fa824a
{{path}}
EO_d0684c052bf3d9c503a8
{{content}}
EO_ecdeef376b1647fa824a
WRITE_edf5
```
description: write or overwrite a file
properties:
 content:
  description: The raw text content to write
  type: string
 path:
  description: The path to the file
  type: string

}, 'prompt ok') or print ">>\n$p\n<<\n";
}

done_testing();
