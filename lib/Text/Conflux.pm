package Text::Conflux;

use strict;
use warnings;
use autodie;
use feature qw< state >;
use File::Slurp qw< slurp >;
use List::Util qw< none >;
use URI;
use Cwd;

## Global Variables.

my @output;
my @toc_lines;
my $toc_exclude_pat;
my $toc_min = 0;
my $toc_max = 10;
my $has_toc;

my $wiki_link_pat            = qq{[:alnum:]&|\,/\-:\. };
my $header_link_pat          = qq{$wiki_link_pat#-};
my $external_link_text_pat   = qq{[:alnum:]:"'\\.,\\?#!\\-\~\%&@\+\(\) };
my $external_link_target_pat = qq{$external_link_text_pat\_/:=&};
my $image_pat                = qq{[:alnum:]%\\-|_\\.:/ };
my $bold_pat                 = qq{[:alnum:]+_!@#$%^\(\)+\\-&,:;=`'?>\\.\\\/" };
my $italic_pat               = qq{[:alnum:]+~!@#$%^\(\)+\\-&,:;=`'?>\\.\\\/" };
my $panel_pat                = "{panel.*";
my $toc_pat                  = "{toc.*";
my $audience_pat             = "{audience.*";
my $code_sample_pat          = "{code:file=([-._a-z]+)}";
my $include_pat              = "{include:file=([-._A-Za-z]+)}";

## Argument processing.

my $add_header_toggles;
my $style_sheet;
my @audiences;
my $title = '';
my $image_directory;
my $include_directory;
my $code_samples_directory;
my $base_url;

# Sane default values for some arguments

my $cwd = getcwd;

$image_directory        //= qq[$cwd/assets/images];
$base_url               //= qq[.];
$include_directory      //= qq[$cwd/assets/includes];
$code_samples_directory //= qq[$cwd/assets/code];
$style_sheet            //= qq[$cwd/assets/css/style.css];

# Toggling header visibility (this may be removed)

my $toggle_js = <<"EOF";
<script type="text/javascript">
<!--
    function toggle_visibility(id) {
       var e = document.getElementById(id);
       if(e.style.display == 'none')
          e.style.display = 'block';
       else
          e.style.display = 'none';
    }
//-->
</script>
EOF

my $toggled_header_seen = 0;

# Specifying a CSS stylesheet.

my $css = "";
$css = slurp $style_sheet if -e $style_sheet;

my $css_block = <<"EOF";
<style type="text/css">
$css
</style>
EOF

# Header and footer templates for valid XHTML output.

my $xml_header;
my $xml_footer;

sub new {

    my $class = shift;
    my $self  = {};

    if ( $style_sheet && $toggle_js ) {
        $xml_header = <<"EOF_HEADER";
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html
     PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"
    "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
  <head>
    <title>$title</title>
    $css_block
    $toggle_js
  </head>
  <body>
EOF_HEADER
    }
    elsif ($style_sheet) {
        $xml_header = <<"EOF_HEADER";
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html
     PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"
    "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
  <head>
    <title>$title</title>
    $css_block
  </head>
  <body>
EOF_HEADER
    }
    else {
        $xml_header = <<"EOF_HEADER";
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html
     PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"
    "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
  <head>
    <title>$title</title>
  </head>
  <body>
EOF_HEADER
    }

    $xml_footer = <<"EOF_FOOTER";
  </body>
</html>
EOF_FOOTER

## Ye Olde Main Input Processing Loop.

    push @output, $xml_header if $title;

    unless ( $toggle_js && $title ) {
        push @output, $toggle_js if $add_header_toggles;
    }

    unless ( $style_sheet && $title ) {
        push @output, $css_block if $style_sheet;
    }

    bless $self, $class;
}

sub convert {
    my ( $self, $text ) = @_;

    open my $handle, '<', \$text;

  LINE: while (<$handle>) {
        state $code             = 0;
        state $info             = 0;
        state $tip              = 0;
        state $note             = 0;
        state $warning          = 0;
        state $htmlcomment      = 0;
        state $table            = 0;
        state $quote            = 0;
        state $audience         = 0;
        state $green            = 0;
        state $current_audience = '';

        next LINE if /$panel_pat/;

        if (/$toc_pat/) {
            push @output, $_;
            next LINE;
        }

        ## We wrap the code below in a DO block so that text is never
        ## modified in any way while we're inside a `{code}' block.  This
        ## change was prompted by two things (so far):
        ##  1. An attempt to format some Objective-C code in one of our
        ## projects.
        ##  2. The need to be able to write a page in Confluence markup
        ## with some examples of Confluence markup wrapped in `{code}'
        ## blocks.

        do {
            # Support for the 'include' macro.  This is useful for slurping in
            # snippets of wiki markup from external files for content reuse.

            # NOTE: Currently only separates paragraphs of text, not the
            # full syntax (such as unordered lists, etc.)

            if (/$include_pat/) {
                die
"Can't use 'include' macro without passing '--include-directory'\n"
                  unless defined $include_directory;
                my $include_pathname = $1;

                s!$include_pat!!g;

                my $file = $include_directory . '/' . $include_pathname;
                my @text = slurp($file);
                my $text = join '<p>', @text;
                s!$_!$text!;
            }

            # Check marks!  Things are done or not done!
            s{\(x\) (.*)}{<input type="checkbox" /> $1}g;
            s{\(/\) (.*)}{<input type="checkbox" checked="yes" /> $1}g;

            # Add a horizontal rule.
            s{^----$}{<hr></hr>};

# External links with custom text, e.g., `[a sample website|http://example.com]'.
            s{\[([$external_link_text_pat]+)\|([$external_link_target_pat]+)\]}
       {<a href="$2">$1</a>}gis;

            # Plain external links, e.g., `[http://example.com]'.
            s{\[([$external_link_target_pat]+)\]}{ _check_for_uri($1)  }ge;

            # Internal links, e.g. `[Mobile Ad Call Reference]'.  See below
            # for the definition of EUNICIZE.
            s{\[([$wiki_link_pat]+)\]}
       {qq[<a href="$base_url/] . _eunicize($1) . qq[">$1</a>]}gise;

            # Links to headers on the same page.  We don't support anchors
            # (yet).
            s{\[#([$header_link_pat]+)\]}
       {<a href="#$1">$1</a>}gis;

            # Images.
s{^\!([$image_pat]+.(png|jpg)).*:([0-9]+)\!}{<p><img width="$3" src="$image_directory/$1"/></p>}gis;

            # Lists of links, optionally followed by a colon or slash, then
            # descriptive text.
            s/^\+ ?(<a href.*<\/a>)([ :\-]?.*)/\<li>$1$2<\/li>/g;
s/^[0-9]\. ?(<a href.*<\/a>)([ :\-]?.*)/\<li class="ordered">$1$2<\/li>/g;

            # Lists of non-link items.
            s/^\+( +.*)$/\<li>$1<\/li>/g;
            s/^[0-9]\.( +.*)$/\<li class="ordered">$1<\/li>/g;

            # Bold elements (Sometimes they occur at the beginning of a
            # line, so we process them before we get to the list section
            # below.
            s/\*([$bold_pat]+)\*/<strong>$1<\/strong>/g;
            s/^\*([$bold_pat]+)\*/<strong>$1<\/strong>/g;

            # Italic elements.
            s/( +|^|\(|\[)\_([$italic_pat]+)\_/$1<em>$2<\/em>/g;

            # Tables.  These still have to be wrapped in a `{table}' macro.
            # Hopefully not for long.
            s{^\|\|}{<tr><th>}gis;    # Beginning of table
            s{\|\| ?\n}{</th></tr>}gis;
            s{\|\|}{</th><th>}gis;        # Middle of columns
            s{\| ?\n$}{</td></tr>}gis;    # End of table row
            s{^\|}{<tr><td>}gis;
            s{\|}{</td><td>}gis;

            # Process headers, 1-6.  We add an appropriate ID to each header's
            # LI tag so that we can use CSS's TEXT-INDENT to create a nice
            # indentation in the table of contents.

            my $header_pat = "^([*]+) ?(.*)\$";
            if (/$header_pat/) {
                my $new;
                my $level;
                $level = length($1);
                if ( $add_header_toggles and $level == 2 ) {
                    $toggled_header_seen++;
                    my $rand = int rand 99999;
                    if ($has_toc) {
                        $new = <<"EOF";
<h$level><a name="$2-TOC"><a href="#-$rand" onclick="toggle_visibility('$2');">&gt;</a>&nbsp;$2</a></h$level>
<div id="$2" style="display: none">
EOF
                    }
                    else {
                        $new = <<"EOF2";
<h$level><a href="#-$rand" onclick="toggle_visibility('$2');">&gt;</a>&nbsp;$2</h$level>
<div id="$2" style="display: none">
EOF2
                    }
                    $new = '</div> ' . $new if $toggled_header_seen > 1;
                }
                else {
                    $new = qq[<h$level><a name="$2-TOC">$2</a></h$level>];
                }
                my $toc_line =
                  qq[<li class="h$level"><a href="#$2-TOC">$2</a></li>];
                push @toc_lines, [ $level, $toc_line ];
                s/$header_pat/$new/;
            }

            # Monospace.
s/\{\{\{?([\[\]\/\\!\?&\@\^\=\#\$0-9\+\*A-Z\.,\-\/>a-z_=:%`'"~\(\) \<\>\n]+}?)}}/<code>$1<\/code>/g;

            # Same-line code blocks.
            s/\{code\}\n?(.*[\n]?)\n?\{code\}/<pre>$1<\/pre>/s;

            # Color TODO statuses in output.
            s{ ?(TODO)}       {<font color="red">$1</font>}g;
            s{ ?(DONE)}       {<font color="green">$1</font>}g;
            s{ ?(IN PROGRESS)}{<font color="orange">$1</font>}g;
            s{ ?(CANCELLED)}  {<font color="gray">$1</font>}g;

            # Support for the 'audience' macro: toggle output based on the
            # intended reader.  This is important for professional-grade
            # technical writing.
            if (/{audience:.*/) {
                $audience++;
                my $audience_type = _parse_audience($_);
                $_                = '';
                $current_audience = $audience_type;
            }
            elsif (/{audience}/) {
                $audience++;
                $_ = '';
            }

            if ( $audience % 2 != 0 ) {
                if ( none { $_ eq $current_audience } @audiences ) {
                    next LINE;
                }
            }

            # Support for an 'include-like' version of the 'code' macro.  This
            # is useful for slurping in code samples from external files
            # (where they can be more easily edited with proper syntax
            # highlighting, indentation, etc.)

            if (/$code_sample_pat/) {
                die
"Can't use '{code:file=FOO}' without passing '--code-samples-directory'\n"
                  unless defined $code_samples_directory;
                my $code_sample_pathname = $1;

                s!$code_sample_pat!!g;

                my $program_file =
                  $code_samples_directory . '/' . $code_sample_pathname;
                my @program_text = slurp($program_file);
                push @output, "<pre>";
                for my $program_line (@program_text) {
                    $program_line =~ s/</&lt;/g;
                    $program_line =~ s/>/&gt;/g;
                    push @output, $program_line;
                }
                push @output, "</pre>";
            }

        } unless $code % 2 != 0;

        # Multiline code blocks.
        $code++ if /\{code\}/;

        if ( $code % 2 != 0 ) {

            # Escape embedded HTML/XML tags inside the code block.  This was
            # necessitated by some XML build cruft for an Android project.
            s/</&lt;/g;
            s/>/&gt;/g;
            s/\{code\}/<pre>/;
        }
        elsif ( $code % 2 == 0 ) {
            s/\{code\}/<\/pre>/;
        }

        # Div-ify the Confluence macros INFO, NOTE, TIP, and WARNING so
        # that we can give them the appropriate colors using CSS.
        $info++ if /{info}/;
        if ( $info % 2 != 0 ) {
            s/{info}/<div class="info">/;
        }
        elsif ( $info % 2 == 0 ) {
            s/{info}/<\/div>/;
        }

        $note++ if /{note}/;
        if ( $note % 2 != 0 ) {
            s/{note}/<div class="note">/;
        }
        elsif ( $note % 2 == 0 ) {
            s/{note}/<\/div>/;
        }

        $tip++ if /{tip}/;
        if ( $tip % 2 != 0 ) {
            s/{tip}/<div class="tip">/;
        }
        elsif ( $tip % 2 == 0 ) {
            s/{tip}/<\/div>/;
        }

        $warning++ if /{warning}/;
        if ( $warning % 2 != 0 ) {
            s/{warning}/<div class="warning">/;
        }
        elsif ( $warning % 2 == 0 ) {
            s/{warning}/<\/div>/;
        }

        $quote++ if /{quote}/;
        if ( $quote % 2 != 0 ) {
            s/{quote}/<blockquote>/;
        }
        elsif ( $quote % 2 == 0 ) {
            s/{quote}/<\/blockquote>/;
        }

        # Support HTML comments. This is one of my favorite macros.
        $htmlcomment++ if /{htmlcomment}/;
        if ( $htmlcomment % 2 != 0 ) {
            s/{htmlcomment}/<!--/;
        }
        elsif ( $htmlcomment % 2 == 0 ) {
            s/{htmlcomment}/-->/;
        }

        # HTML tables need to be wrapped in `{table}' tags.
        $table++ if /{table}/;
        if ( $table % 2 != 0 ) {
            s/{table}/<table>/;
        }
        elsif ( $table % 2 == 0 ) {
            s/{table}/\n<\/table>/;
        }

        # Encode ampersands.
        s/ & / &amp; /g;

        # We know that lines containing headers, tables, and some other
        # types of HTML are not appropriate candidates to be wrapped in
        # paragraph tags, so we push those lines into the output buffer
        # without any further processing.

        if (/(<\/?h[0-9]>|<\/?pre>|<\/?table>|<\/?li>|<\/?div|<\/?hr)/) {
            push @output, $_;
            next LINE;
        }

     # Since all the other transformations are complete, we now know that we can
     # wrap lines of text that are surrounded by newlines in paragraph tags
     # (with a few simple exceptions).  As above, we wrap this in a DO so that
     # code blocks are not modified.

        do {
            s{^([\w \(\)<\/>\.,`'\-!=;:"\^\+~&\$%#\*@\?{}0-9]+)\n+}{<p>$1</p>}g;
        } unless $code % 2 != 0;

        push @output, $_;
    }

    push @output, "</div>" if $toggled_header_seen;

    # This lets the regex matchers do their thing and close 'ol' tags, etc.
    push @output, "\n";

    push @output, $xml_footer if $title;

## Ye Olde Main Output Processing Loop.

  LINE: for my $line (@output) {
        state $inside_ul = 0;
        state $inside_ol = 0;
        if ( $line =~ /$toc_pat/ ) {
            my @result          = _parse_toc($line);
            my $toc_min         = $result[0];
            my $toc_max         = $result[1];
            my $toc_exclude_pat = $result[2];
            $line =
              _replace_toc_line( $line, $toc_min, $toc_max, $toc_exclude_pat );
        }
        elsif ( $line =~ /<li>/ && ( $inside_ul || $inside_ol ) ) {
            next LINE;
        }
        elsif ( $line =~ /<li>/ ) {
            $inside_ul = 1;
            $line      = "<ul>\n" . $line;
            next LINE;
        }
        elsif ( $line =~ /<li class="ordered">/ && !$inside_ol ) {
            $inside_ol = 1;
            $line      = "<ol>\n" . $line;
            next LINE;
        }
        elsif ( $line !~ /<li>/ && $inside_ul ) {
            $inside_ul = 0;
            chomp $line;
            $line .= "</ul>\n";
            next LINE;
        }
        elsif ( $line !~ /<li class="ordered">/ && $inside_ol ) {
            $inside_ol = 0;
            chomp $line;
            $line .= "</ol>\n";
            next LINE;
        }
    }

    print for @output;

}

# Turn a [Wiki Link] into a <a href="wiki-link.html">Wiki Link</a>.

sub _eunicize {

    # String -> String
    my $title = shift;
    $title =~ s/ /-/g;
    $title =~ s/-{2,}/-/g;
    $title =~ s/[^-\w]//gi;
    $title .= '.html';
    return lc $title;
}

# Check if the thing inside the link text is a URI. If so, make it
# into an HTML link; if not, kick it back out as wiki-formatted link
# text for later processing.

sub _check_for_uri {

    # String -> String
    my $it = shift;
    my $retval;

    my $uri    = URI->new($it);
    my $scheme = $uri->scheme;

    if ( defined $scheme ) {
        $retval = qq{<a href="$it">$it</a>};
    }
    else {
        $retval = qq{[$it]};
    }
}

# Table of contents processing goes here.

sub _replace_toc_line {

    # String, Int, Int, Regex -> String
    my ( $line, $min, $max, $pat ) = @_;

    $pat //= "";
    my $result = qq{<div id="toc"><ul>};

    for my $toc_line (@toc_lines) {
        my $line_level = $toc_line->[0];
        my $line_text  = $toc_line->[1];
        if ( ( $min <= $line_level && $line_level <= $max )
            && $line_text !~ $pat )
        {
            $result .= "$line_text\n";
        }
    }
    $result .= qq{</ul></div>};
    $line = $result;
    return $line;
}

sub _parse_toc {

    # String -> Array
    # {toc:minlevel=3|maxlevel=4|Exclude=.*} -> ($min, $max, $pat)
    my $s = shift;
    my @result = ( $toc_min, $toc_max, $toc_exclude_pat );
    if ( $s =~ /\{toc:minlevel=(\d+)\|maxlevel=(\d+)\|exclude=(.*)\}/ ) {
        @result = ( $1, $2, $3 );
    }
    elsif ( $s =~ /\{toc:minlevel=(\d)\|maxlevel=(\d).*/ ) {
        @result = ( $1, $2, "3.14159" );
    }
    elsif ( $s =~ /\{toc:minlevel=(\d).*/ ) {
        @result = ( $1, 10, "3.14159" );
    }
    else {
        return @result;
    }

    return @result;
}

# Parsing the 'audience' macro

sub _parse_audience {

    # String -> String || Undef
    # {audience:FOO}
    my $input = shift;
    my $audience;
    my $retval;
    if ( $input =~ /{audience:([A-Za-z0-9\-]+)/ ) {
        $retval = $1;
        chomp $retval;
    }
    else { $retval = undef; }
    return $retval;
}

1;
