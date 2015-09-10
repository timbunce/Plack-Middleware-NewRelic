package Plack::Middleware::NewRelic;
use parent qw(Plack::Middleware);
use Moo;

use 5.010;
use CHI;
use NewRelic::Agent;
use Plack::Request;
use Plack::Util;

# ABSTRACT: Plack middleware for NewRelic APM instrumentation

has license_key => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_license_key',
);

has app_name => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_app_name',
);

has cache => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_cache',
);

has agent => (
    is      => 'ro',
    lazy    => 1,
    builder => '_build_agent',
);

has transaction_attribute_headers => (
    is      => 'ro',
    builder => '_build_transaction_attribute_headers',
);

has transaction_attribute_params => (
    is      => 'ro',
    builder => '_build_transaction_attribute_params',
);

has path_rules => (
    is      => 'ro',
    default => sub { {} },
);

sub _build_license_key {
    my $self = shift;
    my $license_key = $ENV{NEWRELIC_LICENSE_KEY};
    die 'Missing NewRelic license key' unless $self->license_key;
    return $license_key;
}

sub _build_app_name {
    my $app_name = $ENV{NEWRELIC_APP_NAME};
    die 'Missing NewRelic app name' unless $app_name;
    return $app_name;
}

sub _build_cache {
    return CHI->new(
        driver => 'RawMemory',
        global => 1,
    );
}

sub _build_agent {
    my $self = shift;
    return $self->cache->compute('agent', '5min', sub {
        my $agent = NewRelic::Agent->new(
            license_key => $self->license_key,
            app_name    => $self->app_name,
        );
        $agent->embed_collector;
        $agent->init;
        return $agent;
    });
}

sub _build_transaction_attribute_headers {
    return [ qw/Accept Accept-Language User-Agent/ ];
}

sub _build_transaction_attribute_params {
    return [ ];
}


sub call {
    my ($self, $env) = @_;

    return $self->app->($env) unless $self->agent;

    # XXX ought to use Scope::Guard or a try{} block around the app call
    # otherwise an exception would prevent end_transaction being called
    # Or document that this middleware should be 'outside' one that catches
    # exceptions, such as Plack::Middleware::HTTPException, so it doesn't have
    # to deal with them itself
    $self->begin_transaction($env);

    my $res = $self->app->($env);
 
    if (ref($res) and 'ARRAY' eq ref($res)) {
        $self->end_transaction($env, $res);
        return $res;
    }
 
    return Plack::Util::response_cb(
        $res,
        sub {
            my $res = shift;
            sub {
                my $chunk = shift;
                if (!defined $chunk) {
                    $self->end_transaction($env, $res);
                }
                return $chunk;
            }
        }
    );
}

sub transform_path {
    my ($self, $path) = @_;

    while (my ($pattern, $replacement) = each %{ $self->path_rules }) {
        next unless $pattern && $replacement;
        $path =~ s/$pattern/$replacement/ee;
    }
    return $path;
}


sub begin_transaction {
    my ($self, $env) = @_;
    my $agent = $self->agent;

    # Begin the transaction
    my $txn_id = $agent->begin_transaction;
    return unless $txn_id >= 0;

    my $req = Plack::Request->new($env);
    $env->{TRANSACTION_ID} = $txn_id;

    # Populate initial transaction data

    # This throws an exception if the request_uri doesn't include a path
    # e.g. "/?foo=bar" works but "?foo=bar" throws an exception:
    # "Caught C++ exception of type or derived from 'std::exception': basic_string::_S_construct NULL not valid"
    # This is only likely to hit you when using Plack::Test
    $agent->set_transaction_request_url($txn_id, $req->request_uri);

    my $method = $req->method;
    my $path   = $self->transform_path($req->path);
    my $name   = "$method $path";
    $agent->set_transaction_name($txn_id, $name);

    for my $key (@{ $self->transaction_attribute_headers }) {
        my $value = $req->header($key);
        # the ":" suffix on the key serves to distinguish HTTP headers from params below
        $agent->add_transaction_attribute($txn_id, $key.":", $value)
            if $value;
    }

    # record the whole undecoded query string by default, cheap and useful
    $agent->add_transaction_attribute($txn_id, "QUERY_STRING", $req->query_string);

    for my $key (@{ $self->transaction_attribute_params }) {
        # we use get_all to deal with multiple params with the same name
        my @values = $req->parameters->get_all($key);
        # Keys and values are truncated at 256 bytes.
        # https://docs.newrelic.com/docs/apm/other-features/attributes/agent-attributes#attlimits
        $agent->add_transaction_attribute($txn_id, $key, join(", ", @values))
            if @values;
    }

}


sub end_transaction {
    my ($self, $env, $res) = @_;

    if (my $txn_id = $env->{TRANSACTION_ID}) {
        $self->agent->end_transaction($txn_id);
    }
}

1;

=head1 SYNOPSIS

    use Plack::Builder;
    use Plack::Middleware::NewRelic;
    my $app = sub { ... } # as usual
    # NewRelic Options
    my %options = (
        license_key => 'asdf1234',
        app_name    => 'REST API',
    );
    builder {
        enable "Plack::Middleware::NewRelic", %options;
        $app;
    };

=head1 DESCRIPTION

With the above in place, L<Plack::Middleware::NewRelic> will instrument your
Plack application and send information to NewRelic, using the L<NewRelic::Agent>
module.

=for markdown [![Build Status](https://travis-ci.org/aanari/Plack-Middleware-NewRelic.svg?branch=master)](https://travis-ci.org/aanari/Plack-Middleware-NewRelic)

B<Parameters>

=over 4

=item - C<license_key>

A valid NewRelic license key for your account.

This value is also automatically sourced from the C<NEWRELIC_LICENSE_KEY> environment variable.

=item - C<app_name>

The name of your application.

This value is also automatically sourced from the C<NEWRELIC_APP_NAME> environment variable.

=item - C<path_rules>

A HashRef containing path replacement rules, containing case-insensitive regex patterns as string keys, and evaluatable strings as replacement values.

Regex capturing groups work as intended, so you can specify something like this in your ruleset:

    # Replaces '/pages/new/asdf' with '/pages/new'
    '(\/pages\/new)\/\S+' => '$1'

=back

=cut
