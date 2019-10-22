# CGI::Application::Plugin::OpenTracing

Use OpenTracing in CGI Applications

## SYNOPSIS

inside your CGI Application

```
package MyCGI;

use strict;
use warnings;

use base qw/CGI::Application/;

use CGI::Application::Plugin::OpenTracing;

...

```

and in the various run-modes:

```
sub some_run_mode {
    my $webapp = shift;
    my $q = $webapp->query;
    
    my $some_id = $q->param('some_id');
    $webapp->get_active_span->add_tag( some_id => $some_id );
    
    ...
    
}
```

## DESCRIPTION

This will bootstrap the OpenTracing Implementation and provide a convenience
method `get_active_span`.

It will create a rootspan, for the duration of the entire execution of the
webapp. On top off that root span, it will create three spans for the phases:
setup, run and teardown.
