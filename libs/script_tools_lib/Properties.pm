package Properties;
#############################################################################
# Properties
#
# Added: August 2025
# Last Modified: August 2026
#
# ORIGINAL AUTHORSHIP AND PROVENANCE:
#     This module is a thin integration layer around Config::Properties,
#     originally developed by Randy Jay Yarger, later maintained by
#     Craig Manley, and currently maintained by Salvador Fandino.
#
#     The underlying parsing and properties-handling logic is provided by
#     Config::Properties. All original upstream copyright notices,
#     authorship statements, and licensing terms remain in full effect.
#
# TAF INTEGRATION:
#     Additional glue code, wrappers, and framework integration were added
#     by the MariaDB Foundation as part of the Test Automation Framework.
#     These additions do not alter the upstream license or authorship.
#
# Copyright:
#     Original upstream copyright:
#         See AUTHORS, COPYRIGHT, and LICENSE sections in Config::Properties.
#
#     TAF integration and header additions:
# Copyright (c) 2025-2026 MariaDB Foundation and Jonathan "jeb" Miller
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 or later of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1335 
#
# Licensed under the GNU General Public License, version 2 or later (GPLv2+).
# See https://www.gnu.org/licenses/ for details.
#
#
# PURPOSE:
#     Provide a TAF-friendly wrapper around Java-style .properties files,
#     modeled after java.util.Properties, using Config::Properties as the
#     underlying implementation. This module standardizes loading and
#     accessing .properties files within toolsLib and higher-level TAF
#     components.
#
# ARCHITECTURAL ROLE:
#     - Acts as the unified interface for .properties file handling in TAF.
#     - Delegates parsing and storage to Config::Properties.
#     - Provides a stable, minimal wrapper for loading, querying, and
#       manipulating key/value pairs in Java-style properties files.
#     - Ensures consistent behavior across all TAF components that rely on
#       .properties configuration files.
#
# WHAT THIS MODULE DOES NOT DO:
#     - Does not reimplement Config::Properties functionality.
#     - Does not modify upstream parsing semantics.
#     - Does not provide schema validation or type checking.
#     - Does not guess caller intent or silently coerce values.
#
# CONTRACT:
#     - Must load .properties files using Config::Properties.
#     - Must expose a predictable, minimal API for retrieving values.
#     - Must not alter upstream behavior except where explicitly documented.
#     - Must not die() except on unrecoverable file access errors.
#
# GUARANTEES:
#     - Behavior is deterministic and contributor-proof.
#     - Upstream semantics are preserved exactly.
#     - TAF-specific integration is isolated and documented.
#
# NOTES:
#     - This module exists to provide a stable integration point between
#       Config::Properties and the TAF ecosystem.
#     - Any changes to upstream behavior must be documented in this header
#       and in the TAF manual.
#############################################################################
use strict;
use warnings;

our $VERSION = '1.73';

use IO::Handle;

#------------------------------------------------------------------------------
# Section  : Internal Type Validators
# Purpose  : Provide private helper routines to validate keys, values, formats,
#            validators, and file arguments for Config::Properties.
#
# Details  :
#   - _t_key($)      : Ensures property key is defined and non-empty.
#   - _t_value($)    : Ensures property value is defined (undef not allowed).
#   - _t_format($)   : Ensures format string is defined and contains two '%s'
#                      placeholders in sequence.
#   - _t_validator($): Ensures validator is defined and is a CODE reference.
#   - _t_file($)     : Ensures file argument is defined.
#
# Notes    :
#   - Each routine croaks with a descriptive error message if validation fails.
#   - These are internal helpers, not intended for external use.
#
# Returns  : None directly; croaks on invalid input.
#------------------------------------------------------------------------------
use Carp;

{
    no warnings;
    sub _t_key ($) {
  my $k=shift;
  defined($k) && length($k)
      or croak "invalid property key '$k'";
    }

    sub _t_value ($) {
  my $v=shift;
  defined $v
      or croak "undef is not a valid value for a property";
    }

    sub _t_format ($) {
  my $f=shift;
  defined ($f) && $f=~/\%s.*\%s/
      or croak "invalid format '%f'";
    }

    sub _t_validator ($) {
  my $v=shift;
  defined($v) &&
      UNIVERSAL::isa($v, 'CODE') or
    croak "invalid property validator '$v'";
    }

    sub _t_file ($) {
  my $f=shift;
  defined ($f) or
      croak "invalid file '$f'";
    }
}

#------------------------------------------------------------------------------
# Function : new
# Purpose  : Construct a new Config::Properties object.
#
# Details  :
#   - Accepts one optional argument "$defaultProperties":
#       * May be another Config::Properties instance, used as defaults.
#       * May be a hash reference, which is converted into a Config::Properties.
#   - Alternatively, defaults can be passed via the 'defaults' option key.
#   - Supported option keys:
#       * defaults : Config::Properties object or hash reference.
#       * format   : String format for property output (default '%s=%s').
#       * wrap     : Boolean flag controlling line wrapping (default 1).
#       * file     : Path to a properties file to load at construction.
#   - Any unrecognized option keys cause croak().
#   - If 'file' is provided, the constructor attempts to open and load
#     properties from it immediately.
#
# Returns  : A blessed Config::Properties object instance.
#------------------------------------------------------------------------------
#   new() - Constructor
#
#   The constructor can take one optional argument "$defaultProperties"
#   which is an instance of Config::Properties to be used as defaults
#   for this object.
sub new {
    my $class = shift;
    my $defaults;
    $defaults = shift if @_ & 1;
    my %opts = @_;
    $defaults = delete $opts{defaults} unless defined $defaults;
    my $format = delete $opts{format};
    $format = '%s=%s' unless defined $format;
    my $wrap = delete $opts{wrap};
    $wrap = 1 unless defined $wrap;
    my $file = delete $opts{file};
    %opts and croak "invalid option(s) '" . join("', '", keys %opts) . "'";

    if (defined $defaults) {
        if (ref $defaults eq 'HASH') {
            my $d = Config::Properties->new;
            while (my ($k, $v) = each %$defaults) {
                $d->setProperty($k, $v);
            }
            $defaults = $d;
        }
        elsif (!$defaults->isa('Config::Properties')) {
            croak die "defaults parameter is not a Config::Properties object or a hash"
        }
    }

    my $self = { defaults => $defaults,
     format => $format,
                 wrap => $wrap,
     properties => {},
     next_line_number => 1,
     property_line_numbers => {},
                 file => $file };
    bless $self, $class;

    if (defined $file) {
        open my $fh, '<', $file or croak "unable to open file '$file': $!";
        $self->load($fh);
        close $fh or croak "unable to load file '$file': $!";
    }
    return $self;
}

#------------------------------------------------------------------------------
# Function : changeProperty
# Purpose  : Update a property value only if it differs from the current value.
#
# Details  :
#   - Arguments:
#       * $key      : Property key to update (validated by _t_key).
#       * $new      : New property value (validated by _t_value).
#       * @defaults : Optional defaults passed to getProperty().
#   - Retrieves the existing property value via getProperty().
#   - If the current value is undefined or not equal to the new value,
#     calls setProperty() to update it and returns 1.
#   - If the value is unchanged, no update occurs and returns 0.
#
# Returns  : 1 if the property was updated, 0 if unchanged.
#------------------------------------------------------------------------------
# set property only if its going to change the property value.
#
sub changeProperty {
    my ($self, $key, $new, @defaults) = @_;
    _t_key $key;
    _t_value $new;
    my $old=$self->getProperty($key, @defaults);
    if (!defined $old or $old ne $new) {
  $self->setProperty($key, $new);
  return 1;
    }
    return 0;
}

#------------------------------------------------------------------------------
# Function : deleteProperty
# Purpose  : Remove a property from the current object, and optionally from defaults.
#
# Details  :
#   - Arguments:
#       * $key     : Property key to delete (validated by _t_key).
#       * $recurse : Boolean flag; if TRUE, also delete from defaults.
#   - If the property exists in $self->{properties}, it is removed along with
#     its entry in $self->{property_line_numbers}.
#   - If $recurse is TRUE and $self->{defaults} is defined, calls
#     deleteProperty($key, 1) on the defaults object.
#
# Returns  : None (side effect: property removed from current object and
#            optionally from defaults).
#------------------------------------------------------------------------------
sub deleteProperty {
    my ($self, $key, $recurse) = @_;
    _t_key $key;

    if (exists $self->{properties}{$key}) {
      delete $self->{properties}{$key};
      delete $self->{property_line_numbers}{$key};
    }

    $self->{defaults}->deleteProperty($key, 1)
  if ($recurse and $self->{defaults});
}

#------------------------------------------------------------------------------
# Function : setProperty
# Purpose  : Assign a value to a specific property key.
#
# Details  :
#   - Arguments:
#       * $key   : Property key to set (validated by _t_key).
#       * $value : Property value to assign (validated by _t_value).
#   - Emits a warning via carp() if called in a context expecting a return
#     value, since this routine no longer returns the old value.
#   - Maintains property line numbers:
#       * If the key has no line number yet, assigns the next available one.
#   - Stores the new value in $self->{properties}{$key}.
#
# Returns  : None (side effect: property value updated).
#------------------------------------------------------------------------------
# setProperty() - Set the value for a specific property
sub setProperty {
    my ($self, $key, $value)=@_;
    _t_key $key;
    _t_value $value;

    defined(wantarray) and
  carp "warning: setProperty doesn't return the old value anymore";

    $self->{property_line_numbers}{$key} ||= $self->{next_line_number}++;
    $self->{properties}{$key} = $value;
}

#------------------------------------------------------------------------------
# Function : properties
# Purpose  : Return a flattened hash of all properties.
#
# Details  :
#   - If $self->{defaults} is defined:
#       * Retrieves properties from the defaults object.
#       * Merges them with the current object's properties.
#       * Returns the combined flattened hash.
#   - If no defaults are defined:
#       * Returns only the current object's properties.
#
# Returns  : Hash of property key/value pairs (flattened).
#------------------------------------------------------------------------------
#       properties() - return a flated hash with all the properties
sub properties {
    my $self=shift;
    if (defined ($self->{defaults})) {
  my %p=($self->{defaults}->properties, %{$self->{properties}});
  return %p;
    }
    return %{ $self->{properties} }
}

#------------------------------------------------------------------------------
# Function : getProperties
# Purpose  : Return a hash reference containing all properties.
#
# Details  :
#   - Calls the properties() method to retrieve a flattened hash of all
#     property key/value pairs.
#   - Wraps the returned hash in a hash reference for external use.
#
# Returns  : Hash reference of all property key/value pairs.
#------------------------------------------------------------------------------
# getProperties() - Return a hashref of all of the properties
sub getProperties { return { shift->properties }; }


#------------------------------------------------------------------------------
# Function : getFormat
# Purpose  : Retrieve the output format string used for properties.
#
# Details  :
#   - Accesses the 'format' field from the object.
#   - The format string defines how property key/value pairs are rendered
#     (default is '%s=%s' if not overridden at construction).
#
# Returns  : String containing the current output format.
#------------------------------------------------------------------------------
sub getFormat { shift->{format} }

#------------------------------------------------------------------------------
# Function : setFormat
# Purpose  : Define the output format string for property rendering.
#
# Details  :
#   - Arguments:
#       * $format : Format string to use (validated by _t_format).
#   - If $format is undefined, defaults to '%s=%s'.
#   - Validation ensures the format string contains two '%s' placeholders.
#   - Updates the object's 'format' field with the validated string.
#
# Returns  : None (side effect: output format updated).
#------------------------------------------------------------------------------
# setFormat() - Set the output format for the properties
sub setFormat {
    my ($self, $format) = @_;
    defined $format or $format='%s=%s';
    _t_format $format;
    $self->{format} = $format;
}

#------------------------------------------------------------------------------
# Function : format
# Purpose  : Provide a unified interface for getting or setting the output format.
#
# Details  :
#   - Acts as an alias for getFormat() and setFormat().
#   - If arguments are provided:
#       * Calls setFormat() with the given arguments to update the format.
#   - If no arguments are provided:
#       * Calls getFormat() to return the current format string.
#
# Returns  : Current format string when called without arguments.
#            Result of setFormat() when called with arguments.
#------------------------------------------------------------------------------
sub format {
    my $self = shift;
    if (@_) {
  return $self->setFormat(@_)
    }
    $self->getFormat();
}

#------------------------------------------------------------------------------
# Function : setValidator
# Purpose  : Assign a validation subroutine for property/value pairs.
#
# Details  :
#   - Arguments:
#       * $validator : CODE reference to a subroutine used for validation.
#   - The validator is invoked as:
#         &validator($property, $value, $config)
#       where:
#         * $property : Property key (modifiable via $_[0]).
#         * $value    : Property value (modifiable via $_[1]).
#         * $config   : The Config::Properties object instance.
#   - Allows the validator to enforce rules or transform property/value pairs
#     before they are stored.
#   - Validates that $validator is a CODE reference using _t_validator.
#   - Stores the validator in $self->{validator}.
#
# Returns  : None (side effect: validator set for property/value checks).
#------------------------------------------------------------------------------
#       setValidator(\&validator) - Set sub to be called to validate
#                property/value pairs.  It is called
#                &validator($property, $value, $config) being $config
#                the Config::Properties object.  $property and $key
#                can be modified by the validator via $_[0] and $_[1]
sub setValidator {
    my ($self, $validator) = @_;
    _t_validator $validator;
    $self->{validator} = $validator;
}

#------------------------------------------------------------------------------
# Function : getValidator
# Purpose  : Retrieve the current property/value validator subroutine.
#
# Details  :
#   - Accesses the 'validator' field from the object.
#   - The validator, if defined, is a CODE reference previously set via
#     setValidator().
#   - This subroutine is used to validate or transform property/value pairs
#     during assignment.
#
# Returns  : CODE reference to the current validator subroutine, or undef
#            if none is set.
#------------------------------------------------------------------------------
#       getValidator() - Return the current validator sub
sub getValidator { shift->{validator} }

#------------------------------------------------------------------------------
# Function : validator
# Purpose  : Provide a unified interface for getting or setting the property validator.
#
# Details  :
#   - Acts as an alias for getValidator() and setValidator().
#   - If arguments are provided:
#       * Calls setValidator() with the given arguments to assign a new validator.
#   - If no arguments are provided:
#       * Calls getValidator() to return the current validator subroutine.
#
# Returns  : CODE reference to the current validator when called without arguments.
#            Result of setValidator() when called with arguments.
#------------------------------------------------------------------------------
#       validator() - Alias for get/setValidator();
sub validator {
    my $self=shift;
    if (@_) {
  return $self->setValidator(@_)
    }
    $self->getValidator
}

#------------------------------------------------------------------------------
# Function : load
# Purpose  : Initialize and load properties from a given filehandle.
#
# Details  :
#   - Arguments:
#       * $file : Filehandle to read property lines from (validated by _t_file).
#   - Resets internal state before loading:
#       * Clears $self->{properties}.
#       * Clears $self->{property_line_numbers}.
#       * Resets $self->{next_line_number} to 1.
#   - Iteratively calls process_line($file) to parse each line until EOF.
#   - Each line is processed and stored as a property with its line number.
#
# Returns  : None (side effect: properties loaded into object).
#------------------------------------------------------------------------------
# load() - Load the properties from a filehandle
sub load {
    my ($self, $file) = @_;
    _t_file $file;
    $self->{properties}={};
    $self->{property_line_numbers}={};
    $self->{next_line_number}=1;
    1 while $self->process_line($file);
}

#------------------------------------------------------------------------------
# Functions : escape_key, escape_value, unescape
# Purpose   : Handle escaping and unescaping of property keys and values.
#
# Details   :
#   - escape_key($string)
#       * Escapes special characters in property keys (tabs, newlines, carriage
#         returns, quotes, spaces, '=', ':', etc.).
#       * Non-ASCII characters are converted to Unicode escape sequences
#         (\uXXXX).
#       * Leading spaces and comment markers (#, !) are escaped.
#       * Trailing spaces are preserved with escape sequences.
#
#   - escape_value($string)
#       * Escapes special characters in property values (tabs, newlines,
#         carriage returns, backslashes).
#       * Non-ASCII characters are converted to Unicode escape sequences
#         (\uXXXX).
#       * Leading spaces are escaped.
#
#   - unescape($string)
#       * Converts escaped sequences back to their literal characters.
#       * Handles \t, \n, \r, quotes, spaces, '=', ':', '#', '!', and Unicode
#         escapes (\uXXXX).
#
# Notes     :
#   - Uses %esc and %unesc lookup tables for mapping common escape sequences.
#   - Ensures property keys/values are safely stored and retrieved in
#     Config::Properties files.
#
# Returns   : None directly; modifies the input string in place.
#------------------------------------------------------------------------------
#        escape_key(string), escape_value(string), unescape(string) -
#               subroutines to convert escaped characters to their
#               real counterparts back and forward.

my %esc = ( "\n" => 'n',
      "\r" => 'r',
      "\t" => 't' );
my %unesc = reverse %esc;

sub escape_key {
    $_[0]=~s{([\t\n\r\\"' =:])}{
  "\\".($esc{$1}||$1) }ge;
    $_[0]=~s{([^\x20-\x7e])}{sprintf "\\u%04x", ord $1}ge;
    $_[0]=~s/^ /\\ /;
    $_[0]=~s/^([#!])/\\$1/;
    $_[0]=~s/(?<!\\)((?:\\\\)*) $/$1\\ /;
}

sub escape_value {
    $_[0]=~s{([\t\n\r\\])}{
  "\\".($esc{$1}||$1) }ge;
    $_[0]=~s{([^\x20-\x7e])}{sprintf "\\u%04x", ord $1}ge;
    $_[0]=~s/^ /\\ /;
}

sub unescape {
    $_[0]=~s/\\([tnr\\"' =:#!])|\\u([\da-fA-F]{4})/
  defined $1 ? $unesc{$1}||$1 : chr hex $2 /ge;
}

#------------------------------------------------------------------------------
# Function : process_line
# Purpose  : Read and parse a single line from the properties file.
#
# Details  :
#   - Arguments:
#       * $file : Filehandle to read from.
#   - Reads the next line from the file:
#       * Returns undef if no line is available (EOF).
#   - Line handling:
#       * On the first line, removes UTF-8 byte order mark (BOM) to work
#         around a Perl 5.6.0 unicode bug.
#       * Ignores comment lines starting with '#' or '!'.
#       * Strips trailing CR/LF characters.
#       * Handles continuation lines ending with an odd number of backslashes:
#           - Removes the trailing backslash.
#           - Concatenates subsequent lines, stripping leading whitespace.
#   - Parsing:
#       * Splits line into key and value using regex.
#       * Calls fail() if the line does not match the expected property format.
#   - Post processing:
#       * Unescapes key and value.
#       * Validates them via validate().
#       * Records line number in property_line_numbers.
#       * Updates next_line_number.
#       * Stores the property key/value in $self->{properties}.
#
# Returns  : 1 on success, undef at EOF.
#------------------------------------------------------------------------------
# process_line() - read and parse a line from the properties file.

# this is to workaround a bug in perl 5.6.0 related to unicode
my $bomre = eval(q< qr/^\\x{FEFF}/ >) || qr//;

sub process_line {
    my ($self, $file) = @_;
    my $line = <$file>;

    defined $line or return undef;

    my $ln = $self->{line_number} = $file->input_line_number;

    # remove utf8 BOM on first line
    if ($ln == 1) {
        $line =~ s/$bomre//;
    }

    # ignore comments and blank lines
    $line =~ /^\s*(\#|\!|$)/ and return 1;

    # ignore ANY bracketed section header: [xxx]
    $line =~ /^\s*\[[^\]]+\]\s*$/ and return 1;

    # strip CRLF
    $line =~ s/\x0D*\x0A$//;

    if ($line =~ /db_config_start/i) {
        $self->{skip_db_config} = 1;
        return 1;
    }

    if ($line =~ /db_config_end/i) {
        $self->{skip_db_config} = 0;
        return 1;
    }

    if ($self->{skip_db_config}) {
        return 1;
    }

    # handle continuation lines
    my @lines;
    while ($line =~ /(\\+)$/ and length($1) & 1) {
        $line =~ s/\\$//;
        push @lines, $line;
        $line = <$file>;
        $line =~ s/\x0D*\x0A$//;
        $line =~ s/^\s+//;
    }

    $line = join('', @lines, $line) if @lines;

    # allow key-only boolean flags
    if ($line =~ /^\s*([^\s:=\\]+)\s*$/) {
        my $key = $1;
        unescape $key;
        $self->{validate}->($key, 1) if $self->{validate};
        $self->{property_line_numbers}{$key} = $ln;
        $self->{next_line_number} = $ln + 1;
        $self->{properties}{$key} = 1;
        return 1;
    }

    # parse key/value
    my ($key, $value) = $line =~ /^\s*((?:[^\s:=\\]|\\.)+)\s*[:=\s]\s*(.*)$/x
        or $self->fail("invalid property line '$line'");

    unescape $key;
    unescape $value;

    $self->validate($key, $value);

    $self->{property_line_numbers}{$key} = $ln;
    $self->{next_line_number} = $ln + 1;

    $self->{properties}{$key} = $value;

    return 1;
}

#------------------------------------------------------------------------------
# Function : validate
# Purpose  : Apply the configured validator subroutine to a property/value pair.
#
# Details  :
#   - Retrieves the current validator from $self->{validator}.
#   - If a validator is defined:
#       * Invokes it with arguments (@_, $self), where:
#           - $_[0] : Property key
#           - $_[1] : Property value
#           - $self : Config::Properties object
#       * The validator may transform or reject the key/value.
#       * If the validator returns false, calls fail() with an explicit error
#         message indicating the invalid key/value.
#
# Returns  : None (side effect: validation performed; may raise error on failure).
#------------------------------------------------------------------------------
sub validate {
    my $self=shift;
    my $validator = $self->{validator};
    if (defined $validator) {
  &{$validator}(@_, $self) or $self->fail("invalid value '$_[1]' for '$_[0]'");
    }
}

#------------------------------------------------------------------------------
# Function : line_number
# Purpose  : Retrieve the line number of the last line read from the configuration file.
#
# Details  :
#   - Accesses the 'line_number' field from the object.
#   - This value is updated during parsing (e.g., in process_line) to track
#     the current position in the file.
#
# Returns  : Integer representing the last line number read.
#------------------------------------------------------------------------------
#       line_number() - number for the last line read from the configuration file
sub line_number { shift->{line_number} }

#------------------------------------------------------------------------------
# Function : fail
# Purpose  : Report and terminate execution on configuration file errors.
#
# Details  :
#   - Arguments:
#       * $error : Error message string describing the issue.
#   - Constructs a detailed error message including:
#       * The provided error description.
#       * The line number of the last line read (via line_number()).
#   - Terminates execution immediately using die(), ensuring the error is
#     surfaced to the caller with context.
#
# Returns  : None (execution halts with error message).
#------------------------------------------------------------------------------
#       fail(error) - report errors in the configuration file while reading.
sub fail {
    my ($self, $error) = @_;
    die "$error at line ".$self->line_number()."\n";
}

#------------------------------------------------------------------------------
# Function : _save
# Purpose  : Utility routine to write all properties to a filehandle.
#
# Details  :
#   - Arguments:
#       * $file : Filehandle to which properties are written (validated by _t_file).
#   - Wrap handling:
#       * If $self->{wrap} is true, attempts to load Text::Wrap.
#       * Requires Text::Wrap version 2001.0929 or newer; otherwise warns that
#         long lines will not be wrapped.
#       * Configures Text::Wrap local settings:
#           - separator : " \\\n"
#           - unexpand  : undef
#           - huge      : 'overflow'
#           - break     : regex to wrap only on unescaped spaces.
#   - Iteration:
#       * Sorts property keys by their original line numbers (stored in
#         property_line_numbers).
#       * Escapes keys and values before writing.
#   - Output:
#       * If wrapping is enabled, uses Text::Wrap::wrap() to format long lines.
#       * Otherwise, prints each property using the object's format string.
#
# Returns  : None (side effect: properties written to filehandle).
#------------------------------------------------------------------------------
# _save() - Utility function that performs the actual saving of
#   the properties file to a filehandle.
sub _save {
    my ($self, $file) = @_;
    _t_file $file;

    my $wrap;
    if ($self->{wrap}) {
        eval {
            no warnings;
            require Text::Wrap;
            $wrap=($Text::Wrap::VERSION >= 2001.0929);
        };
        unless ($wrap) {
            carp "Text::Wrap module is to old, version 2001.0929 or newer required: long lines will not be wrapped"
        }
    }

    # Edited by Jeb (Jonthan Miller) from MariaDB Dec 2005 to suppress useless warnings
    {
        no warnings 'once';
        local($Text::Wrap::separator) = " \\\n"       if $wrap;
        local($Text::Wrap::unexpand)  = undef         if $wrap;
        local($Text::Wrap::huge)      = 'overflow'    if $wrap;
        local($Text::Wrap::break)     = qr/(?<!\\) (?! )/ if $wrap;
    }

    my $sk=$self->{property_line_numbers};
    foreach (sort { $sk->{$a} <=> $sk->{$b} } keys %{$self->{properties}}) {
  my $key=$_;
  my $value=$self->{properties}{$key};
  escape_key $key;
  escape_value $value;

  if ($wrap) {
      $file->print( Text::Wrap::wrap( "",
              "    ",
              sprintf( $self->{'format'},
                 $key, $value ) ),
        "\n" );
  }
  else {
      $file->print(sprintf( $self->{'format'}, $key, $value ), "\n")
  }
    }
}

#------------------------------------------------------------------------------
# Function : save
# Purpose  : Save all properties to a filehandle, optionally including a header.
#
# Details  :
#   - Arguments:
#       * $file   : Filehandle to write properties to (validated by _t_file).
#       * $header : Optional header text to prepend to the file.
#   - Behavior:
#       * If a header is provided:
#           - Replaces newline characters with "# \n" to format as comments.
#           - Prints the header lines prefixed with '#' followed by a blank line.
#       * Prints a timestamp line (localtime) as a comment for reference.
#       * Calls _save() to write all properties in the configured format.
#
# Returns  : None (side effect: properties written to filehandle).
#------------------------------------------------------------------------------
# save() - Save the properties to a filehandle with the given header.
sub save {
    my ($self, $file, $header) = @_;
    _t_file($file);

    if (defined $header) {
  $header=~s/\n/# \n/sg;
  print $file "# $header\n#\n";
    }
    print $file '# ' . localtime() . "\n\n";
    $self->_save( $file );
}

#------------------------------------------------------------------------------
# Function : saveToString
# Purpose  : Save all properties into an in-memory string instead of a file.
#
# Details  :
#   - Arguments:
#       * Accepts optional header text (passed through to save()).
#   - Behavior:
#       * Creates a scalar string reference ($str) and opens it as a filehandle
#         for writing.
#       * Calls save() to write properties into the in-memory filehandle.
#       * Closes the filehandle, ensuring the string is fully written.
#   - Error Handling:
#       * Dies with an explicit message if the string reference cannot be opened
#         or closed properly.
#
# Returns  : String containing the serialized properties and optional header.
#------------------------------------------------------------------------------
sub saveToString {
    my $self = shift;
    my $str; # = '';
    open my $fh, '>', \$str
  or die "unable to open string ref as file";
    $self->save($fh, @_);
    close $fh
  or die "unable to write to in memory file";
    return $str;
}

#------------------------------------------------------------------------------
# Function : _split_to_tree
# Purpose  : Convert flat property keys into a hierarchical tree structure.
#
# Details  :
#   - Arguments:
#       * $tree  : Hash reference to populate with hierarchical structure.
#       * $re    : Regular expression used to split property keys into parts.
#       * $start : Optional prefix to strip from keys before splitting.
#
#   - Behavior:
#       * If defaults are defined, recursively calls _split_to_tree on them
#         to merge default properties into the tree.
#       * Iterates over all property keys in $self->{properties}.
#           - Strips $start prefix if provided; skips key if prefix not found.
#           - Splits the key into parts using $re.
#           - Builds nested hash levels for each part.
#           - If a part already exists:
#               - If it is a hashref, descends into it.
#               - If it is a scalar, replaces it with a hash containing
#                 the scalar under key ''.
#           - For the final part:
#               - Assigns the property value.
#               - If the final node is already a hashref, stores the value
#                 under key ''.
#
#   - This routine effectively transforms dotted or delimited property keys
#     into a nested hash tree, preserving hierarchy and handling collisions.
#
# Returns  : None (side effect: $tree populated with hierarchical properties).
#------------------------------------------------------------------------------
sub _split_to_tree {
    my ($self, $tree, $re, $start) = @_;
    if (defined $self->{defaults}) {
  $self->{defaults}->_split_to_tree($tree, $re, $start);
    }
    for my $key (keys %{$self->{properties}}) {
        my $ekey = $key;

        if (defined $start) {
            $ekey =~ s/$start// or next;
        }

  my @parts = split $re, $ekey;
  @parts = '' unless @parts;
  my $t = $tree;
  while (@parts) {
      my $part = shift @parts;
      my $old = $t->{$part};

      if (@parts) {
    if (defined $old) {
        if (ref $old) {
      $t = $old;
        }
        else {
      $t = $t->{$part} = { '' => $old };
        }
    }
    else {
        $t = $t->{$part} = {};
    }
      }
      else {
    my $value = $self->{properties}{$key};
    if (ref $old) {
        $old->{''} = $value;
    }
    else {
        $t->{$part} = $value;
    }
      }
  }
    }
}

#------------------------------------------------------------------------------
# Function : splitToTree
# Purpose  : Build a hierarchical tree structure from flat property keys.
#
# Details  :
#   - Arguments:
#       * $re    : Regular expression delimiter for splitting keys.
#                  Defaults to '.' if not provided.
#       * $start : Optional prefix; if defined, keys must begin with this
#                  prefix followed by the delimiter to be included.
#
#   - Behavior:
#       * Ensures $re is a compiled regex (defaults to qr/\./).
#       * If $start is provided:
#           - Escapes it with quotemeta.
#           - Constructs a regex to match keys beginning with $start + delimiter.
#       * Initializes an empty hashref ($tree).
#       * Calls _split_to_tree() to populate $tree with hierarchical
#         structure based on property keys.
#
# Returns  : Hash reference representing the hierarchical property tree.
#------------------------------------------------------------------------------
sub splitToTree {
    my ($self, $re, $start) = @_;
    $re = qr/\./ unless defined $re;
    $re = qr/$re/ unless ref $re;
    if (defined $start) {
        $start = quotemeta $start;
        $start = qr/^$start$re/
    }
    my $tree = {};
    $self->_split_to_tree($tree, $re, $start);
    $tree;
}

#------------------------------------------------------------------------------
# Function : _unsplit_from_tree
# Purpose  : Flatten a hierarchical tree structure back into key/value pairs.
#
# Details  :
#   - Arguments:
#       * $method : Method name to call for each flattened key/value pair.
#       * $tree   : Current node in the hierarchical structure (HASH, ARRAY, or scalar).
#       * $sep    : Separator used to join key parts (defaults to '.').
#       * @start  : Accumulated path parts leading to the current node.
#
#   - Behavior:
#       * If $tree is a HASH:
#           - Iterates over each key.
#           - Recursively descends into child nodes, appending the key
#             (unless it is an empty string).
#       * If $tree is an ARRAY:
#           - Iterates over indices.
#           - Recursively descends into each element, appending the index.
#       * If $tree is another reference type:
#           - Throws an error (croak) since only HASH/ARRAY are expected.
#       * If $tree is a scalar (leaf node):
#           - Joins accumulated parts with $sep to form the flattened key.
#           - Calls $method on $self with the flattened key and its value.
#
#   - This routine effectively reverses _split_to_tree, reconstructing
#     flat property keys from nested structures.
#
# Returns  : None (side effect: invokes $method for each flattened property).
#------------------------------------------------------------------------------
sub _unsplit_from_tree {
    my ($self, $method, $tree, $sep, @start) = @_;
    $sep = '.' unless defined $sep;
    my $ref = ref $tree;
    if ($ref eq 'HASH') {
        for my $key (keys %$tree) {
            $self->_unsplit_from_tree($method, $tree->{$key}, $sep,
                               @start, ($key ne '' ? $key : ()))
        }
    }
    elsif ($ref eq 'ARRAY') {
        for my $key (0..$#$tree) {
            $self->_unsplit_from_tree($method, $tree->[$key], $sep, @start, $key)
        }
    }
    elsif ($ref) {
        croak "unexpected object '$ref' found inside tree"
    }
    else {
        $self->$method(join($sep, @start), $tree)
    }
}

sub setFromTree { shift->_unsplit_from_tree(setProperty => @_) }
sub changeFromTree { shift->_unsplit_from_tree(changeProperty => @_) }

# store() - Synonym for save()
sub store { shift->save(@_) }

#------------------------------------------------------------------------------
# Function : getProperty
# Purpose  : Retrieve the value of a property key, with fallback to defaults.
#
# Details  :
#   - Arguments:
#       * $key : Property key to look up (validated by _t_key).
#       * @_   : Optional list of default values to use if neither properties
#                nor defaults contain the key.
#
#   - Behavior:
#       * Checks if the key exists in $self->{properties}.
#           - If yes, returns its value.
#       * Otherwise, if a defaults object is defined:
#           - Delegates lookup to $self->{defaults}->getProperty().
#       * Otherwise, iterates through provided fallback values (@_):
#           - Returns the first defined value.
#       * If no value is found, returns undef.
#
# Returns  : Property value, a default value, or undef if none exist.
#------------------------------------------------------------------------------
# getProperty() - Return the value of a property key. Returns the default
#   for that key (if there is one) if no value exists for that key.
sub getProperty {
    my $self = shift;
    my $key = shift;
    _t_key $key;

    if (exists $self->{properties}{$key}) {
  return $self->{properties}{$key}
    }
    elsif (defined $self->{defaults}) {
  return $self->{defaults}->getProperty($key, @_);
    }
    for (@_) {
  return $_ if defined $_
    }
    undef
}

#------------------------------------------------------------------------------
# Function : requireProperty
# Purpose  : Retrieve a property value and enforce its existence.
#
# Details  :
#   - Arguments:
#       * First argument : Property key to look up.
#       * Remaining args : Optional default values passed to getProperty().
#
#   - Behavior:
#       * Calls getProperty() to retrieve the value for the given key.
#       * If the property is not defined:
#           - Terminates execution with die(), reporting the missing key and
#             indicating it was required but not found in the configuration file.
#       * If the property exists, returns its value.
#
# Returns  : Property value (scalar).
#------------------------------------------------------------------------------
sub requireProperty {
    my $this = shift;
    my $prop = $this->getProperty(@_);
    defined $prop
  or die "required property '$_[0]' not found on configuration file\n";
    return $prop;
}

#------------------------------------------------------------------------------
# Function : _property_line_number
# Purpose  : Retrieve the stored line number for a given property key.
#
# Details  :
#   - Arguments:
#       * $key : Property key whose line number is requested.
#   - Behavior:
#       * Looks up the key in $self->{property_line_numbers}.
#       * Returns the line number associated with that property, if present.
#       * If the key has not been recorded, returns undef.
#
# Returns  : Integer line number or undef if the key is not tracked.
#------------------------------------------------------------------------------
sub _property_line_number {
    my ($self, $key)=@_;
    $self->{property_line_numbers}{$key}
}

#------------------------------------------------------------------------------
# Function : propertyNames
# Purpose  : Return a list of all property keys currently defined.
#
# Details  :
#   - Calls properties() to retrieve the flattened hash of all properties.
#   - Extracts and returns the keys from that hash.
#   - Provides a simple way to enumerate all property names without values.
#
# Returns  : Array of property keys (list context).
#------------------------------------------------------------------------------
# propertyName() - Returns an array of the keys of the Properties
sub propertyNames {
    my %p=shift->properties;
    keys %p;
}

#############################################################################
# Module terminator
#############################################################################
1;
__END__

=head1 NAME

Config::Properties - Read and write property files

=head1 SYNOPSIS

  use Config::Properties;

  # reading...

  open my $fh, '<', 'my_config.props'
    or die "unable to open configuration file";

  my $properties = Config::Properties->new();
  $properties->load($fh);

  $value = $properties->getProperty($key);


  # saving...

  open my $fh, '>', 'my_config.props'
    or die "unable to open configuration file for writing";

  $properties->setProperty($key, $value);

  $properties->format('%s => %s');
  $properties->store($fh, $header );


=head1 DESCRIPTION

Config::Properties is a near implementation of the
java.util.Properties API.  It is designed to allow easy reading,
writing and manipulation of Java-style property files.

The format of a Java-style property file is that of a key-value pair
seperated by either whitespace, the colon (:) character, or the equals
(=) character.  Whitespace before the key and on either side of the
seperator is ignored.

Lines that begin with either a hash (#) or a bang (!) are considered
comment lines and ignored.

A backslash (\) at the end of a line signifies a continuation and the
next line is counted as part of the current line (minus the backslash,
any whitespace after the backslash, the line break, and any whitespace
at the beginning of the next line).

The official references used to determine this format can be found in
the Java API docs for java.util.Properties at
L<http://java.sun.com/j2se/1.5.0/docs/api/java/util/Properties.html>.

When a property file is saved it is in the format "key=value" for each
line. This can be changed by setting the format attribute using either
$object->format( $format_string ) or $object->setFormat(
$format_string ) (they do the same thing). The format string is fed to
printf and must contain exactly two %s format characters. The first
will be replaced with the key of the property and the second with the
value. The string can contain no other printf control characters, but
can be anything else. A newline will be automatically added to the end
of the string. The current format string can be obtained by using
$object->format() (with no arguments) or $object->getFormat().

If a recent version of L<Text::Wrap> is available, long lines are
conveniently wrapped when saving.

=head1 METHODS

C<Config::Property> objects have this set of methods available:

=over 4

=item Config::Properties-E<gt>new(%opts)

Creates a new Config::Properties object.

The optional arguments are as follows:

=over 4

=item file => $filename

Opens and reads the entries from the given properties file

=item format => $format

Sets the format using for saving the properties to a file. See
L</setFormat>.

=item defaults => $defaults

Default configuration values.

The given parameter can be a hash reference or another
Config::Properties object.

In that way several configuration objects can be chained. For
instance:

  my %defaults = (...);
  my $global_config = Config::Properties->new(file => '/etc/foo.properties',
                                              defaults => \%defaults);
  my $user_config = Config::Properties->new(file => '/home/jsmith/.foo/foo.properties',
                                            defaults => $global_config);

=back

=item Config::Properties-E<gt>new($defaults)

Calling C<new> in this way is deprecated.

=item $p-E<gt>getProperty($k, $default, $default2, ...)

return property C<$k> or when not defined, the first defined
C<$default*>.

=item $p-E<gt>requireProperty($k, $default, $default2, ...)

this method is similar to C<getProperty> but dies if the requested
property is not found.

=item $p-E<gt>setProperty($k, $v)

set property C<$k> value to C<$v>.

=item $p-E<gt>changeProperty($k, $v)

=item $p-E<gt>changeProperty($k, $v, $default, $default2, ...)

method similar to C<setPropery> but that does nothing when the new
value is equal to the one returned by C<getProperty>.

An example shows why it is useful:

  my $defaults=Config::Properties->new();
  $defaults->setProperty(foo => 'bar');

  my $p1=Config::Properties->new($defaults);
  $p1->setProperty(foo => 'bar');   # we set here!
  $p1->store(FILE1); foo gets saved on the file

  my $p2=Config::Properties->new($defaults);
  $p2->changeProperty(foo => 'bar'); # does nothing!
  $p2->store(FILE2); # foo doesn't get saved on the file

=item $p-E<gt>deleteProperty($k)

=item $p-E<gt>deleteProperty($k, $recurse)

deletes property $k from the object.

If C<$recurse> is true, it also deletes any C<$k> property from the
default properties object.

=item $p-E<gt>properties

returns a flatten hash with all the property key/value pairs, i.e.:

  my %props=$p->properties;

=item $p-E<gt>getProperties

returns a hash reference with all the properties (including those passed as defaults).

=item $p-E<gt>propertyNames;

returns the names of all the properties (including those passed as defaults).

=item $p-E<gt>splitToTree()

=item $p-E<gt>splitToTree($regexp)

=item $p-E<gt>splitToTree($regexp, $start)

builds a tree from the properties, splitting the keys with the regular
expression C<$re> (or C</\./> by default). For instance:

  my $data = <<EOD;
  name = pete
  date.birth = 1958-09-12
  date.death = 2004-05-11
  surname = moo
  surname.length = 3
  EOD

  open my $fh, '<', \$data;
  $cfg->load();
  my $tree = $cfg->splitToTree();

makes...

  $tree = { date => { birth => '1958-09-12',
                      death => '2004-05-11' },
            name => 'pete',
            surname => { '' => 'moo',
                         length => '3' } };



The C<$start> parameter allows to split only a subset of the
properties. For instance, with the same data as on the previous
example:

   my $subtree = $cfg->splitToTree(qr/\./, 'date');

makes...

  $tree = { birth => '1958-09-12',
            death => '2004-05-11' };

=item $p-E<gt>setFromTree($tree)

=item $p-E<gt>setFromTree($tree, $separator)

=item $p-E<gt>setFromTree($tree, $separator, $start)

This method sets properties from a tree of Perl hashes and arrays. It
is the opposite to splitToTree.

C<$separator> is the string used to join the parts of the property
names. The default value is a dot (C<.>).

C<$start> is a string used as the starting point for the property
names.

For instance:

  my $c = Config::Properties->new;
  $c->setFromTree( { foo => { '' => one,
                              hollo => [2, 3, 4, 1] },
                     bar => 'doo' },
                   '->',
                   'mama')

  # sets properties:
  #      mama->bar = doo
  #      mama->foo = one
  #      mama->foo->hollo->0 = 2
  #      mama->foo->hollo->1 = 3
  #      mama->foo->hollo->2 = 4
  #      mama->foo->hollo->3 = 1


=item $p-E<gt>changeFromTree($tree)

=item $p-E<gt>changeFromTree($tree, $separator)

=item $p-E<gt>changeFromTree($tree, $separator, $start)

similar to C<setFromTree> but internally uses C<changeProperty>
instead of C<setProperty> to set the property values.


=item $p-E<gt>load($file)

loads properties from the open file C<$file>.

Old properties on the object are forgotten.

=item $p-E<gt>save($file)

=item $p-E<gt>save($file, $header)

=item $p-E<gt>store($file)

=item $p-E<gt>store($file, $header)

save the properties to the open file C<$file>. Default properties are
not saved.

=item $p-E<gt>saveToString($header)

similar to C<save>, but instead of saving to a file, it returns a
string with the content.

=item $p-E<gt>getFormat()

=item $p-E<gt>setFormat($f)

X<setFormat>get/set the format string used when saving the object to a file.

=back

=head1 SEE ALSO

Java docs for C<java.util.Properties> at
L<http://java.sun.com/j2se/1.3/docs/api/index.html>.

L<Config::Properties::Simple> for a simpler alternative interface to
L<Config::Properties>.

=head1 AUTHORS

C<Config::Properties> was originally developed by Randy Jay Yarger. It
was mantained for some time by Craig Manley and finally it passed
hands to Salvador FandiE<ntilde>o <sfandino@yahoo.com>, the current
maintainer.

=head1 COPYRIGHT AND LICENSE

Copyright 2001, 2002 by Randy Jay Yarger
Copyright 2002, 2003 by Craig Manley.
Copyright 2003-2009, 2011 by Salvador FandiE<ntilde>o.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

