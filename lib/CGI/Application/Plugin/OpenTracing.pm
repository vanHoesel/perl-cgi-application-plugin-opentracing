package CGI::Application::Plugin::OpenTracing;

use strict;
use warnings;

our $VERSION = '0.01';

use base 'Exporter';

use OpenTracing::Implementation;
use OpenTracing::GlobalTracer;

use Time::HiRes qw( gettimeofday );


our @implementation_import_params;

sub import {
    my $package = shift;
    @implementation_import_params = @_;
    
    my $caller  = caller;
    
    $caller->add_callback( init     => \&init     );
        
    $caller->add_callback( prerun   => \&prerun   );
    
    $caller->add_callback( postrun  => \&postrun  );
    
    $caller->add_callback( teardown => \&teardown );
    
}



sub init {
    my $cgi_app = shift;
    
    my $tracer = _init_opentracing_implementation($cgi_app);
    $cgi_app->{__PLUGINS}{OPENTRACING}{TRACER} = $tracer;

    my $context = $tracer->extract_context;
    
    $cgi_app->{__PLUGINS}{OPENTRACING}{SCOPE}{CGI_REQUEST} =
        $tracer->start_active_span( 'cgi_request', child_of => $context );
    $cgi_app->{__PLUGINS}{OPENTRACING}{SCOPE}{CGI_REQUEST}
        ->get_span->add_tags(
            'component'             => 'CGI::Application',
            'http.method'           => _cgi_get_http_method($cgi_app),
            'http.status_code'      => '000',
            'http.url'              => _cgi_get_http_url($cgi_app),
        );
    
    $cgi_app->{__PLUGINS}{OPENTRACING}{SCOPE}{CGI_SETUP} =
        $tracer->start_active_span( 'cgi_setup');
}



sub prerun {
    my $cgi_app = shift;
    
    my $baggage_items = _get_baggage_items($cgi_app);
    
    $cgi_app->{__PLUGINS}{OPENTRACING}{SCOPE}{CGI_SETUP}
        ->get_span->add_baggage_items( %{$baggage_items} );
    
    $cgi_app->{__PLUGINS}{OPENTRACING}{SCOPE}{CGI_SETUP}->close;
    
    $cgi_app->{__PLUGINS}{OPENTRACING}{SCOPE}{CGI_REQUEST}
        ->get_span->add_baggage_items( %{$baggage_items} );
    $cgi_app->{__PLUGINS}{OPENTRACING}{SCOPE}{CGI_REQUEST}
        ->get_span->add_tags(
            'runmode'               => _get_current_runmode($cgi_app),
            'runmethod'             => _cgi_get_run_method($cgi_app),
        );
    
    my $tracer = $cgi_app->{__PLUGINS}{OPENTRACING}{TRACER};
    
    $cgi_app->{__PLUGINS}{OPENTRACING}{SCOPE}{CGI_RUN} =
        $tracer->start_active_span( 'cgi_run');
    
    return
}



sub postrun {
    my $cgi_app = shift;
    
    $cgi_app->{__PLUGINS}{OPENTRACING}{SCOPE}{CGI_RUN}->close;
    
    return
}



sub teardown {
    my $cgi_app = shift;
    
    $cgi_app->{__PLUGINS}{OPENTRACING}{SCOPE}{CGI_REQUEST}->close;
    
    return
}



sub _init_opentracing_implementation {
    my $cgi_app = shift;
    
    my @implementation_settings = @implementation_import_params;
    
    my $default_span_context = get_default_span_context($cgi_app);
    $cgi_app->{__PLUGINS}{OPENTRACING}{DEFAULT_CONTEXT} = $default_span_context;
    
    push @implementation_settings, (
        default_span_context_args => $default_span_context,
    ) if $default_span_context;
    
    OpenTracing::Implementation
        ->bootstrap_global_tracer( @implementation_settings );
    
    return
}



sub _start_active_root_span {
    my $cgi_app = shift;
    
    my $context = _get_global_tracer->extract_context;
    
    my $root_span_options = _get_root_span_options( $cgi_app );
    
    my $scope = _get_global_tracer->start_active_span( 'cgi_application' =>
        %{$root_span_options},
        child_of => $context,
    );
    
    _span_set_scope( $cgi_app, 'request', $scope );
    
    return $scope
}



sub _get_root_span_options {
    my $cgi_app = shift;
    
    return {
        child_of                => undef, # will be overridden
        tags                    => {
            'component'             => 'CGI::Application',
            'http.method'           => _cgi_get_http_method( $cgi_app ),
            'http.status_code'      => '200',
            'http.url'              => _cgi_get_http_url( $cgi_app ),
        },
        start_time              => _span_get_time_start( $cgi_app, 'request' ),
        ignore_active_span      => 1,
    }
}



sub _handle_postmortum_setup_span {
    my $cgi_app = shift;
    
    my $method = _cgi_get_run_method( $cgi_app );
    my $operation_name = 'setup';
    
    _get_global_tracer
    ->start_span( $operation_name =>
        start_time => _span_get_time_start( $cgi_app, 'setup' ),
    )
    ->finish( _span_get_time_finish( $cgi_app, 'setup' )
    )
}



sub _start_active_run_span {
    my $cgi_app = shift;
    
    my $method = _cgi_get_run_method( $cgi_app );
    my $operation_name = 'run';
    
    my $scope = _get_global_tracer->start_active_span( $operation_name );
    
    _span_set_scope( $cgi_app, 'run', $scope );
    
    return $scope
}



sub _cgi_get_run_method {
    my $cgi_app = shift;
    
    my $run_mode = $cgi_app->get_current_runmode();
    my $run_methode = { $cgi_app->run_modes }->{ $run_mode };
    
    return $run_methode
}



sub _span_set_time_start {
    _span_set_time( $_[0], $_[1], 'start' );
}



sub _span_set_time_finish {
    _span_set_time( $_[0], $_[1], 'finish' );
}



sub _span_set_time {
    $_[0]->{__PLUGINS}{OpenTracing}{__SPANS}{$_[1]}{ $_[2] . '_time' }
    = scalar @_ == 4 ? $_[3] : _epoch_floatingpoint();
;
}



sub _span_get_time_start {
    _span_get_time( $_[0], $_[1], 'start' );
}



sub _span_get_time_finish {
    _span_get_time( $_[0], $_[1], 'finish' );
}



sub _span_get_time {
    $_[0]->{__PLUGINS}{OpenTracing}{__SPANS}{$_[1]}{$_[2].'_time'};
}



sub _span_scope_close {
    _span_get_scope( $_[0], $_[1] )->close;
}



sub _span_set_scope {
    $_[0]->{__PLUGINS}{OpenTracing}{__SPANS}{$_[1]}{scope} = $_[2];
}



sub _span_get_scope {
    $_[0]->{__PLUGINS}{OpenTracing}{__SPANS}{$_[1]}{scope};
}



sub _cgi_get_http_method {
    my $cgi_app = shift;
    
    my $query = $cgi_app->query();
    
    return $query->request_method();
}



sub _cgi_get_http_url {
    my $cgi_app = shift;
    
    my $query = $cgi_app->query();
    
    return $query->url();
}



sub _epoch_floatingpoint {
    return scalar gettimeofday()
}



sub get_opentracing_global_tracer {
    OpenTracing::GlobalTracer->get_global_tracer()
}



1;
