package CGI::Application::Plugin::OpenTracing;

use strict;
use warnings;

our $VERSION = 'v0.102.0';

use syntax 'maybe';

use OpenTracing::Implementation;
use OpenTracing::GlobalTracer;

use Carp qw( croak carp );
use HTTP::Headers;
use HTTP::Status;
use Time::HiRes qw( gettimeofday );

use constant CGI_LOAD_TMPL => 'cgi_application_load_tmpl';
use constant CGI_REQUEST   => 'cgi_application_request';
use constant CGI_RUN       => 'cgi_application_run';
use constant CGI_SETUP     => 'cgi_application_setup';
use constant CGI_TEARDOWN  => 'cgi_application_teardown';

our $implementation_import_name;
our @implementation_import_opts;

use constant FALLBACK_HASH_KEY => "\0-%:FALLBACK:%-\0";
sub fallback (&) { return (FALLBACK_HASH_KEY, $_[0]) }

sub import {
    my $package = shift;
    
    ( $implementation_import_name, @implementation_import_opts ) = @_;
    $ENV{OPENTRACING_DEBUG} && carp "OpenTracing Implementation not defined during import\n"
        unless defined $implementation_import_name;
    
    my $caller  = caller;
    $caller->add_callback( init      => \&init      );
    $caller->add_callback( prerun    => \&prerun    );
    $caller->add_callback( postrun   => \&postrun   );
    $caller->add_callback( load_tmpl => \&load_tmpl );
    $caller->add_callback( teardown  => \&teardown  );
    
    no strict 'refs';
    *{ $caller . '::fallback' } = \&fallback;
}



sub init {
    my $cgi_app = shift;
    
    _plugin_init_opentracing_implementation( $cgi_app );
    
    my %request_tags = _get_request_tags($cgi_app);
    my %query_params = _get_query_params($cgi_app);
    my %form_data    = _get_form_data($cgi_app);
    my $context      = _tracer_extract_context( $cgi_app );
    
    _plugin_start_active_span( $cgi_app, CGI_REQUEST, child_of => $context  );
    _plugin_add_tags(          $cgi_app, CGI_REQUEST, %request_tags         );
    _plugin_add_tags(          $cgi_app, CGI_REQUEST, %query_params         );
    _plugin_add_tags(          $cgi_app, CGI_REQUEST, %form_data            );
    _plugin_start_active_span( $cgi_app, CGI_SETUP                          );
    
    return
}



sub prerun {
    my $cgi_app = shift;
    
    my %runmode_tags  = _get_runmode_tags($cgi_app);
    my %baggage_items = _get_baggage_items($cgi_app);
    
    _plugin_add_baggage_items( $cgi_app, CGI_SETUP,   %baggage_items        );
    _plugin_close_scope(       $cgi_app, CGI_SETUP                          );
    _plugin_add_baggage_items( $cgi_app, CGI_REQUEST, %baggage_items        );
    _plugin_add_tags(          $cgi_app, CGI_REQUEST, %runmode_tags         );
    _plugin_start_active_span( $cgi_app, CGI_RUN                            );
    
    return
}



sub postrun {
    my $cgi_app = shift;
    
    _plugin_close_scope(       $cgi_app, CGI_RUN                            );
    _plugin_start_active_span( $cgi_app, CGI_TEARDOWN                       );
    
    return
}



sub load_tmpl {
    my $cgi_app = shift;
    
    _plugin_close_scope(       $cgi_app, CGI_LOAD_TMPL                      );
    
    return
}



sub teardown {
    my $cgi_app = shift;
    
    my %http_status_tags = _get_http_status_tags($cgi_app);
    
    _plugin_close_scope(       $cgi_app, CGI_TEARDOWN                       );
    _plugin_add_tags(          $cgi_app, CGI_REQUEST, %http_status_tags     );
    _plugin_close_scope(       $cgi_app, CGI_REQUEST                        );
    
    return
}



sub _init_global_tracer {
    my $cgi_app = shift;
    
    my @bootstrap_options = _get_bootstrap_options($cgi_app);
    
    my $bootstrapped_tracer =
        $implementation_import_name ?
            OpenTracing::Implementation->bootstrap_tracer(
                $implementation_import_name,
                @implementation_import_opts,
                @bootstrap_options,
            )
            :
            OpenTracing::Implementation->bootstrap_default_tracer(
                @implementation_import_opts,
                @bootstrap_options,
            )
    ;
    
    OpenTracing::GlobalTracer->set_global_tracer( $bootstrapped_tracer );
    
    return
}



sub _cgi_get_run_mode {
    my $cgi_app = shift;
    
    my $run_mode = $cgi_app->get_current_runmode();
    
    return $run_mode
}



sub _cgi_get_run_method {
    my $cgi_app = shift;
    
    my $run_mode = $cgi_app->get_current_runmode();
    my $run_methode = { $cgi_app->run_modes }->{ $run_mode };
    
    return $run_methode
}



sub _cgi_get_http_method {
    my $cgi_app = shift;
    
    my $query = $cgi_app->query();
    
    return $query->request_method();
}


sub _cgi_get_http_headers { # TODO: extract headers from CGI request
    my $cgi_app = shift;
    return HTTP::Headers->new();
}


sub _cgi_get_http_url {
    my $cgi_app = shift;
    
    my $query = $cgi_app->query();
    
    return $query->url(-path => 1);
}



=for not_implemented
sub get_opentracing_global_tracer {
    OpenTracing::GlobalTracer->get_global_tracer()
}
=cut



sub _get_request_tags {
    my $cgi_app = shift;
    
    my %tags = (
              'component'   => 'CGI::Application',
        maybe 'http.method' => _cgi_get_http_method($cgi_app),
        maybe 'http.url'    => _cgi_get_http_url($cgi_app),
    );
    

    return %tags
}

sub _gen_tag_processor {
    my $cgi_app = shift;

    my $join_str = do {
        no strict 'refs';
        ${ ref($cgi_app) . '::OPENTRACING_TAG_JOIN_CHAR' };
    } // ',';
    my $joiner = sub { join $join_str, @_ };

    my @specs = map { { $_->() } } grep { defined } @_;
    my ($fallback) = map { delete $_->{ (FALLBACK_HASH_KEY) } // () } @specs;
    $fallback ||= $joiner;

    return sub {
        my ($cgi_app, $name, $values) = @_;
        
        my $processor = $fallback;
        foreach my $spec (@specs) {
            $processor = $spec->{$name} if exists $spec->{$name};
        }

        return            if not defined $processor;
        return $processor if not ref $processor;

        if (ref $processor eq 'CODE') {
            my $processed = $processor->(@$values);
            $processed = $joiner->(@$processed) if ref $processed eq 'ARRAY';
            return $processed;
        }

        croak "Invalid processor for param `$name`: ", ref $processor;
    };
}

sub _get_query_params {
    my $cgi_app = shift;

    my $processor = _gen_tag_processor($cgi_app,
        $cgi_app->can('opentracing_process_tags_query_params'),
        $cgi_app->can('opentracing_process_tags'),
    );

    my %processed_params;

    my $query = $cgi_app->query();
    foreach my $param ($query->url_param()) {
        next unless defined $param; # huh ???
        my @values          = $query->url_param($param);
        my $processed_value = $cgi_app->$processor($param, \@values);
        next unless defined $processed_value;

        $processed_params{"http.query.$param"} = $processed_value;
    }
    return %processed_params;
}

sub _get_form_data {
    my $cgi_app = shift;
    my $query = $cgi_app->query();
    return unless _has_form_data($query);
    
    my $processor = _gen_tag_processor($cgi_app,
        $cgi_app->can('opentracing_process_tags_form_fields'),
        $cgi_app->can('opentracing_process_tags'),
    );
    
    my %processed_params = ();
    
    my %params = $cgi_app->query->Vars();
    while (my ($param_name, $param_value) = each %params) {
        my $processed_value = $cgi_app->$processor(
            $param_name, [ split /\0/, $param_value ]
        );
        next unless defined $processed_value;
        $processed_params{"http.form.$param_name"} = $processed_value
    }
    
    return %processed_params;
}

sub _has_form_data {
    my ($query) = @_;
    my $content_type = $query->content_type();
    return   if not defined $content_type;
    return 1 if $content_type =~ m{\Amultipart/form-data};
    return 1 if $content_type =~ m{\Aapplication/x-www-form-urlencoded};
    return;
}

sub _get_runmode_tags {
    my $cgi_app = shift;
    
    my %tags = (
        maybe 'run_mode'   => _cgi_get_run_mode($cgi_app),
        maybe 'run_method' => _cgi_get_run_method($cgi_app),
    );
    return %tags
}

sub _get_http_status_tags {
    my $cgi_app = shift;
    
    my %headers = $cgi_app->header_props();
    my $status = $headers{-status} or return (
        'http.status_code'    => '200',
    );
    my $status_code = [ $status =~ /^\s*(\d{3})/ ]->[0];
    my $status_mess = [ $status =~ /^\s*\d{3}\s*(.+)\s*$/ ]->[0];
    
    $status_mess = HTTP::Status::status_message($status_code)
        unless defined $status_mess;
    
    my %tags = (
        maybe 'http.status_code'    => $status_code,
        maybe 'http.status_message' => $status_mess,
    );
    return %tags
}


sub _get_bootstrap_options {
    my $cgi_app = shift;
    
    return unless $cgi_app->can('opentracing_bootstrap_options');
    
    my @bootstrap_options = $cgi_app->opentracing_bootstrap_options( );
    
    return @bootstrap_options
}



sub _get_baggage_items {
    my $cgi_app = shift;
    
    return unless $cgi_app->can('opentracing_baggage_items');
    
    my %baggage_items = $cgi_app->opentracing_baggage_items( );
    
    
    return %baggage_items
}



sub _tracer_extract_context {
    my $cgi_app = shift;
    
    my $http_headers = _cgi_get_http_headers($cgi_app);
    my $tracer = _plugin_get_tracer( $cgi_app );
    
    return $tracer->extract_context($http_headers)
}

sub _plugin_get_tracer {
    my $cgi_app = shift;
    return $cgi_app->{__PLUGINS}{OPENTRACING}{TRACER}
}

sub _plugin_init_opentracing_implementation {
    my $cgi_app = shift;
    
    _init_global_tracer($cgi_app);
#       unless OpenTracing::GlobalTracer->is_registered;
    my $tracer = OpenTracing::GlobalTracer->get_global_tracer;
    
    $cgi_app->{__PLUGINS}{OPENTRACING}{TRACER} = $tracer;
}

sub _plugin_start_active_span {
    my $cgi_app        = shift;
    my $operation_name = shift;
    my %params         = @_;
    my $scope_name     = uc $operation_name;
    
    my $scope =
    _tracer_start_active_span( $cgi_app, $operation_name, %params );
    
    $cgi_app->{__PLUGINS}{OPENTRACING}{SCOPE}{$scope_name} = $scope;
}

sub _tracer_start_active_span {
    my $cgi_app        = shift;
    my $operation_name = shift;
    my %params         = @_;
    
    my $tracer = _plugin_get_tracer($cgi_app);
    $tracer->start_active_span( $operation_name, %params );
}

sub _plugin_add_tags {
    my $cgi_app        = shift;
    my $operation_name = shift;
    my %tags           = @_;
    my $scope_name     = uc $operation_name;

    $cgi_app->{__PLUGINS}{OPENTRACING}{SCOPE}{$scope_name}
        ->get_span->add_tags(%tags);
}

sub _plugin_add_baggage_items {
    my $cgi_app        = shift;
    my $operation_name = shift;
    my %baggage_items  = @_;
    my $scope_name     = uc $operation_name;
    
    $cgi_app->{__PLUGINS}{OPENTRACING}{SCOPE}{$scope_name}
        ->get_span->add_baggage_items( %baggage_items );
}

sub _plugin_close_scope {
    my $cgi_app        = shift;
    my $operation_name = shift;
    my $scope_name     = uc $operation_name;
    
    $cgi_app->{__PLUGINS}{OPENTRACING}{SCOPE}{$scope_name}->close
}



1;
