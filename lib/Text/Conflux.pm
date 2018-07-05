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

__END__

=head1 NAME

Text::Conflux - Convert Conflux document markup syntax to (X)HTML

=head1 SYNOPSIS

From the command line:

    $ conflux < input.txt > output.html

From Perl code:

    use Text::Conflux;

    my $c = Text::Conflux->new(
        {
            header_toggles  => 1,
            stylesheet      => qq[/path/to/file.css],
            audience        => 'enterprise_users',
            title           => 'Page Title',
            image_dir       => '/path/to/images',
            include_dir     => '/path/to/includes',
            code_sample_dir => '/path/to/code',
            # Or '/local/dir'
            base_url        => 'https://www.example.com'
        }
    );

    my $html = $c->convert($text);

=head1 DESCRIPTION

Conflux is a markup language that combines elements of Confluence/JIRA
wiki markup and Emacs outline-mode.

The C<conflux> command included with this module is a command line
filter that takes in a stream of text in Conflux format and prints it
out as HTML.

Unlike some other markup languages, Conflux syntax provides features
that are important for technical documents.  For example:

=over

=item Plaintext Table Syntax

You can use Confluence's table syntax instead of having to write HTML
tables by hand.  This matters B<a lot> if you create and maintain
technical documents. (See L</"Tables"> below.)

=item Automatic Tables of Contents

You can use the C<toc> macro to have a nice table of contents
generated for your document.  (See L</"Tables of Contents"> below).

=back

Note that syntax highlighting plugins for Vim and Emacs are included
in this distribution.

=head1 SUPPORTED MARKUP

The subset of Confluence markup that we support is defined as follows:

=over

=item Headers

The C<*> header format from Emacs outline mode is supported, as in
C<** Introduction>.  No other formatting inside the header text is
supported. For example, C<** Introduction to {{confluence2html}}> will
not work.

=item Links

Standard links are supported, e.g., C<[Link to some other page on this
wiki]>.  This will be rewritten to link to a local file named
C<base_url/link-to-some-other-page-on-this-wiki.html> using the
C<base_url> argument to the constructor.  If no such file exists, this
will be a broken link until that file is created.  The easiest (but
not only) way to do this is to have another file of Confluence markup
in the same directory named
C<base_url/link-to-some-other-page-on-this-wiki.txt>, and to generate
it at the same time.

External links are supported:

    [Perl home page|http://www.perl.org]

    [http://www.example.org]

Confluence space keys are not supported, since the concept of "spaces"
has no meaning in terms of processing a stream of text, which is what
this module does.  However, a space feature could be added by a more
sophisticated application built atop this module.

=item Macros

Conflux supports a few Confluence-inspired "macros" -- text tags that wrap a section of content and define how that content is processed.

The supported macros are mainly those that are required for a
reasonable "publish your writing to HTML" experience.  Here's the
list:

=over

=item C<code>

=item C<info>

=item C<tip>

=item C<note>

=item C<warning>

=item C<htmlcomment>

=item C<table>

=item C<toc>

=back

Other than C<toc>, these macros can only be written as single tags on
their own line that delimit blocks of text.  For example:

    {info}
    Have some informative text!
    {info}

Unlike old skool Confluence wiki markup, no arguments of the form
C<{info:title=I am the Title}> are supported. If you want to add a
title your C<info> block for readers, try something like the
following:

    {info}
    *Important Information!*
    Your coffee is ready.
    {info}

Note that the C<info>, C<tip>, C<note>, C<warning>, and C<toc> macros
output as C<div> tags with class names that correspond to the macro
name for easy CSS styling.  Example output:

    <div class="info">
    <p>These instructions assume that you have already installed and
    correctly configured... For more information, see ... </p>
    </div>

This makes it trivial to do things like add background colors for
emphasis and the like.

=item Tables of Contents

Prints a table of contents with links to some or all headers on the
page.  The following arguments are supported (in addition to none at
all): C<minlevel>, C<maxlevel>, C<exclude> -- and they must be
supplied in that order.  In other words, you must use the C<toc> macro
in one of the following ways:

=over

=item C<{toc}>

Prints a table of contents using all headers on the page.

=item C<{toc:minlevel=2}>

Prints a table of contents with a minimum header size of C<2>.  The
C<minlevel> argument must be an integer between 1 and 6.

=item C<{toc:minlevel=2|maxlevel=4}>

prints a table of contents with a minimum header size of C<2> and a
maximum header size of C<4>. C<minlevel> and C<maxlevel> must be
integers between 1 and 6.

=item C<{toc:minlevel=2|maxlevel=4|exclude=Further.*}>

Prints a table of contents with a minimum header size of C<2> and a
maximum header size of C<4>, with any headers matching C<Further.*>
(such as "Further Reading") being excluded.

C<minlevel> and C<maxlevel> must be integers between 1 and 6, and
C<exclude> is a Perl regular expression literal -- note that the
regular expression is not surrounded by quotes.

=back

=item Lists

Ordered and unordered lists are supported.  Example:

    + Apple
    + Banana
    + Cherry

    1. Rhubarb
    2. Tomato
    3. Pomegranate

=item Line Breaks

The line breaks that appear in the HTML output are those that appear
in the text file.  There is no support for the Confluence forced line
break C<\\>.

=item Tables

Tables are supported.  The only requirement is that you must wrap the
table itself in the C<{table}> macro, e.g.:

    {table}
    | *Name*               | *Rank*   | *Serial Number* |
    | Steven Fluffernutter | Sergeant | 314159          |
    | Christopher Crunch   | Captain  | 271828          |
    | ...                  | ...      | ...             |
    | ...                  | ...      | ...             |
    {table}

Tip: If you use Emacs, you can use the
L<orgtbl|https://orgmode.org/manual/Orgtbl-mode.html> minor mode to
navigate, edit, and pretty-print the table contents.

=item Images

Images are supported, with the following syntax:

    !foo.png:450!

This will insert C<foo.png> into the output, at 450 pixels in width.
In order for C<Text::Conflux> to know where to find C<foo.png>, you
must pass the C<image_dir> variable to the constructor.

=back

=head1 BUGS

Many bugs are lurking in this code.  Please L<file
issues|https://github.com/rmloveland/Text-Conflux/issues/new> for any
that you find.

=head1 AUTHOR

Rich Loveland, L<mailto:r@rmloveland.com>
