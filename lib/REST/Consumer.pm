package REST::Consumer;
# a generic client for talking to restful web services

use strict;
use warnings;

use LWP::UserAgent;
use URI;
use JSON::XS;
use HTTP::Request;
use HTTP::Headers;
use File::Path qw( mkpath );
use REST::Consumer::RequestException;

our $VERSION = '0.07';

my $global_configuration = {};
my %service_clients;
my $data_path = $ENV{DATA_PATH} || $ENV{TMPDIR} || '/tmp';
my $throw_exceptions = 1;

# make sure config gets loaded from url every 5 minutes
my $config_reload_interval = 60 * 5;

sub throw_exceptions {
	my ($class, $value) = @_;
	$throw_exceptions = $value if defined $value;
	return $throw_exceptions;
}

sub configure {
	my ($class, $config, @args) = @_;
	if (!ref $config) {
		if ($config =~ /^https?:/) {
			# if the config is a scalar that starts with http:, assume it's a url to fetch configuration from
			my $uri = URI->new($config);
			my ($dir, $filename) = _config_file_path($uri);

			my @stat = stat("$dir/$filename");
			my $age_in_seconds = time - $stat[9];

			$config = load_config_from_file("$dir/$filename", \@stat);

			# reload config from url if it's older than 10 minutes
			if (!$config || ($age_in_seconds && $age_in_seconds > $config_reload_interval)) {
				my $client = $class->new( host => $uri->host, port => $uri->port );
				$config = $client->get( path => $uri->path );

				# try to cache config loaded from a url to a file for fault tolerance
				write_config_to_file($uri, $config);
			}
		} else {
			# otherwise it's a filename
			my $path = $config;
			$config = load_config_from_file($path);
		}
	}

	if (ref $config ne 'HASH') {
		die "Invalid configuration. It should either be a hashref or a url or filename to get config data from";
	}

	for my $key (keys %$config) {
		$global_configuration->{$key} = _validate_client_config($config->{$key});
	}

	return 1;
}

sub _config_file_path {
	my ($uri) = @_;
	my $cache_filename = $uri->host . '-' . $uri->port . $uri->path . '.json';
#	$cache_filename =~ s/\//-/g;
	my ($dir, $filename) = $cache_filename =~ /(.*)\/([^\/]*)/i;
	return ("$data_path/rest-consumer/config/$dir", $filename);
}

sub load_config_from_file {
	my ($path, $stat) = @_;
	my @stat = $stat || stat($path);
	return if !-e _ || !-r _;

	undef $/;
	open my $config_fh, $path or die "Couldn't open config file '$path': $!";

	my $data = <$config_fh>;
	my $decoded_data = JSON::XS::decode_json($data);
	close $config_fh;
	return $decoded_data;
}

sub write_config_to_file {
	my ($url, $config) = @_;
	my ($dir, $filename) = _config_file_path($url);

	eval { mkpath($dir) };
	if ($@) {
		warn "Couldn’t create make directory for rest consumer config $dir: $@";
		return;
	}

#	if (!-w "$dir/$filename") {
#		warn "Can't write config data to: $dir/$filename - not caching rest consumer config data";
#		return;
#	}

	open my $cache_file, '>', "$dir/$filename"
		or die "Couldn't open config file for write '$dir/$filename': $!";

	print $cache_file JSON::XS::encode_json($config);
	close $cache_file;
}

sub service {
	my ($class, $name) = @_;
	return $service_clients{$name} if defined $service_clients{$name};

	die "No service configured with name: $name"
		if !exists $global_configuration->{$name};

	$service_clients{$name} = $class->new(%{$global_configuration->{$name}});
	return $service_clients{$name};
}

sub _validate_client_config {
	my ($config) = @_;
	my $valid = {
		host    => $config->{host},
		url     => $config->{url},
		port    => $config->{port},

		# timeout on requests to the service
		timeout => $config->{timeout} || 10,

		# retry this many times if we don't get a 200 response from the service
		retry   => exists $config->{retry} ? $config->{retry} : exists $config->{retries} ? $config->{retries} : 0,

		# print some extra debugging messages
		verbose => $config->{verbose} || 0,

		# enable persistent connection
		keep_alive => $config->{keep_alive} || 1,

		agent => $config->{user_agent} || "REST-Consumer/$VERSION",

		auth => $config->{auth} || {},
	};

	if (!$valid->{host} and !$valid->{url}) {
		die "Either host or url is required";
	}

	return $valid;
}

sub new {
	my ($class, @args) = @_;
	my $args = {};
	if (scalar @args == 1 && !ref $args[0]) {
		$args->{url} = $args[0];
	} else {
		$args = { @args };
	}
	my $self = _validate_client_config($args);
	bless $self, $class;
	return $self;
}

sub host {
	my ($self, $host) = @_;
	$self->{host} = $host if defined $host;
	return $self->{host};
}

sub port {
	my ($self, $port) = @_;
	$self->{port} = $port if defined $port;
	return $self->{port};
}

sub timeout {
	my ($self, $timeout) = @_;
	$self->{timeout} = $timeout if defined $timeout;
	return $self->{timeout};
}

sub keep_alive {
	my ($self, $keep_alive) = @_;
	$self->{keep_alive} = $keep_alive if defined $keep_alive;
	return $self->{keep_alive};
}

sub agent {
	my ($self, $agent) = @_;
	$self->{agent} = $agent if defined $agent;
	return $self->{agent};
}

sub last_request {
	my ($self) = @_;
	return $self->{_last_request};
}

sub last_response {
	my ($self) = @_;
	return $self->{_last_response};
}

sub get_user_agent { user_agent(@_) }

sub user_agent {
	my $self = shift;
	return $self->{_user_agent} if defined $self->{_user_agent};

	# if keep alive is enabled, create a connection that persists globally
	my @lwp_args = (
		timeout => $self->timeout(),
		agent   => $self->agent(),
		($self->keep_alive ? ( keep_alive => $self->keep_alive ) : ()),
	);
	my $user_agent = LWP::UserAgent->new(@lwp_args);

	# handle auth headers
	my $default_headers = HTTP::Headers->new;
	$default_headers->header( 'accept' => 'application/json' );

	if (exists $self->{auth} && $self->{auth}{type} && $self->{auth}{type} eq 'basic') {
		$default_headers->authorization_basic($self->{auth}{username}, $self->{auth}{password});
	}

	$user_agent->default_headers($default_headers);
	$self->{_user_agent} = $user_agent;
	return $user_agent;
}


# create the base url for the request composed of the host and port
# add http if it hasn't already been prepended
sub get_service_base_url {
	my $self = shift;
	return $self->{url} if $self->{url};

	my $host = $self->{host};
	my $port = $self->{port};
	$host =~ s|/$||;

	return sprintf("%s$host%s", $host =~ m|^https?://| ? '' : 'http://', $port ? ":$port" : '');
}

# return a URI object containing the url and any query parameters
# path: the url
# params: an array ref or hash ref containing key/value pairs to add to the URI
sub get_uri {
	my $self = shift;
	my %args = @_;
	my $path = $args{path};
	my $params = $args{params};
	$path =~ s|^/||;

	# replace any sinatra-like url tokens with their param value
	if (ref $params eq 'HASH') {
		$path =~ s/\:(\w+)/delete $params->{$1} || $1/eg;
	}

	my $uri = URI->new( sprintf("%s/$path",$self->get_service_base_url()) );
	# accept key / values in hash or array format
	my @params = ref($params) eq 'HASH' ? %$params : ref($params) eq 'ARRAY' ? @$params : ();
	$uri->query_form( @params );
	return $uri;
}

# get an http request object for the given input
sub get_http_request {
	my $self     = shift;
	my %args     = @_;
	my $path     = $args{path} or die 'path is a required argument.  e.g. "/" ';
	my $content     = $args{content};
	my $headers  = $args{headers};
	my $params   = $args{params};
	my $method   = $args{method} or die 'method is a required argument';
	my $content_type = $args{content_type};

	# build the uri from path and params
	my $uri = $self->get_uri(path => $path, params => $params);

	$self->debug( sprintf('Creating request: %s %s', $method, $uri->as_string() ));

	# add headers if present
	my $full_headers = $self->user_agent->default_headers || HTTP::Headers->new;
	if ($headers) {
		my @header_params = ref($headers) eq 'HASH' ? %$headers : ref($headers) eq 'ARRAY' ? @$headers : ();
		$full_headers->header(@header_params);
	}

	# assemble request
	my $req = HTTP::Request->new($method => $uri, $full_headers);

	$self->add_content_to_request(
		request      => $req,
		content_type => $content_type,
		content      => $content,
	);


	return $req;
}


# add content to the request
# by default, serialize to json
# otherwise use content type to determine any action if needed
# content type defaults to application/json
sub add_content_to_request {
	my $self = shift;
	my %args = @_;
	my $request = $args{request} or die 'request is required';
	my $content_type = $args{content_type} || 'application/x-www-form-urlencoded';
	my $content = $args{content};

	return unless defined($content) && length($content);

	$request->content_type($content_type);
	if ($content_type eq 'application/x-www-form-urlencoded') {
		# We use a temporary URI object to format
		# the application/x-www-form-urlencoded content.
		my $url = URI->new('http:');
		if (ref $content eq 'HASH') {
			$url->query_form(%$content);
		} elsif (ref $content eq 'ARRAY') {
			$url->query_form(@$content);
		} else {
			$url->query($content);
		}
		$content = $url->query;

		# HTML/4.01 says that line breaks are represented as "CR LF" pairs (i.e., `%0D%0A')
		$content =~ s/(?<!%0D)%0A/%0D%0A/g;
		$request->content($content);
	} elsif ($content_type eq 'application/json') {
		my $json = ref($content) ? JSON::XS::encode_json($content) : $content;
		$request->content($json);
	} elsif ($content_type eq 'multipart/form-data') {
		$request->content($content);
	} else {
		# if content type is something else, just include the raw data here
		# modify this code if we need to process other content types differently
		$request->content($content);
	}
}

# send a request to the given path with the given method, params, and content body
# and get back a response object
#
# path: the location of the resource on the given hostname.  e.g. '/path/to/resource'
# content: optional content body to send in a post.  e.g. a json document
# params: an arrayref or hashref of key/value pairs to include in the request
# headers: a list of key value pairs to add to the header
# method: get,post,delete,put,head
#
# depending on the value of $self->retry this function will retry a request if it receives an error.
# In the future we may want to consider managing this based on the specific error code received.
sub get_response {
	my $self     = shift;
	my %args     = @_;
	my $path     = $args{path} or die 'path is a required argument.  e.g. "/" ';
	my $content  = $args{content} || $args{body};
	my $headers  = $args{headers};
	my $params   = $args{params};
	my $method   = $args{method} or die 'method is a required argument';
	my $content_type = $args{content_type};
	my $retry_count = defined $args{retry} ? $args{retry} : $self->{retry};

	my $req = $self->get_http_request(
		path     => $path,
		content  => $content,
		headers  => $headers,
		params   => $params,
		method   => $method,
		content_type => $content_type,
	);

	# run the request
	my $response = $self->get_response_for_request(http_request => $req, retry => $retry_count);
	return $response;
}

# do everything that get_response does, but return the deserialized content in the response instead of the response object
sub get_processed_response {
	my $self = shift;
	my $response = $self->get_response(@_);
	# convert json content to perl
	my $response_content = $self->deserialize_content($response);

	return $response_content;
}

sub deserialize_content {
	my ($self, $response) = @_;
	return if !$response;

	# parse response content, if present
	my $response_content;
	my $content_type = $response->header('Content-Type');
	if ($content_type && $content_type =~ m|.+/json|) {
		eval {
			$response_content = JSON::XS::decode_json($response->decoded_content() );
			1;
		} or do {
			# might or might not be an error.  e.g. if content is empty or is just a string
			$self->debug(sprintf("failed to parse json response: %s\n%s\n",
				$response->decoded_content(),
				$@,
			));
			$response_content = $response->decoded_content();
		};
	} else {
		# if we can' determine content type, return raw data
		$response_content = $response->decoded_content();
	}

	return $response_content;
}


#
# http_request => an HTTP Request object
# _retries => how many times we've already tried to get a valid response for this request
sub get_response_for_request {
	my ($self, %args) = @_;
	my $http_request = $args{http_request};

	my $user_agent = $self->user_agent;
	my $response = $user_agent->request($http_request);

	$self->{_last_request} = $http_request;
	$self->{_last_response} = $response;
	$self->debug( sprintf('Got response: %s', $response->code()));

	if ($response and $response->is_success()) {
		return $response;
	}

	# handle failure

	# don't bother retrying on certain errors (but err on the side of retrying for others)
	# 403 Forbidden
	# 404 Not Found
	# 405 Method not allowed
	# 413 Request Entity to large
	if (!$args{retry} or scalar grep {$response->code() == $_} qw(403 404 405 413)) {
		return if !$throw_exceptions;
		REST::Consumer::RequestException->throw(
			request  => $http_request,
			response => $response,
		);
	}


	$args{_attempts} ||= 0;
	$args{_attempts}++;

	# die if we've exceeded the retry limit
	if ($args{_attempts} > $args{retry}) {
		return if !$throw_exceptions;
		REST::Consumer::RequestException->throw(
			request  => $http_request,
			response => $response,
			attempts => $args{_attempts},
		);
#		croak sprintf("Request Failed after %s retries: %s %s\n %s %s\n%s\n",
#			$args{_attempts},
#			$http_request->method(),
#			$http_request->uri()->as_string(),
#			$response->code(),
#			defined($response->message()) ? $response->message() : '',
#			$self->{verbose} ? $response->content() : '',
#		);
	}
	printf STDERR "Error (%s) %s. Retrying.\n", $response->code(), $response->message() || '';

	# retry this request with update retry count
	return $self->get_response_for_request(%args);
}

sub head {
	my $self = shift;
	return $self->get_response(@_, method => 'HEAD');
}

sub get {
	my $self = shift;
	return $self->get_processed_response(@_, method => 'GET');
}

sub post {
	my $self = shift;
	return $self->get_processed_response(@_, method => 'POST');
}

sub delete {
	my $self = shift;
	return $self->get_processed_response(@_, method => 'DELETE');
}

sub put {
	my $self = shift;
	return $self->get_response(@_, method => 'PUT');
}


# print status messages to stderr if running in verbose mode
sub debug {
	my $self = shift;
	return unless $self->{verbose};
	local $\ = "\n";
	print STDERR @_;
}

1;
__END__

=head1 Name

REST::Consumer - General client for interacting with json data in HTTP Restful services

=head1 Synopsis

This module provides an interface that encapsulates building an http request, sending the request, and parsing a json response.  It also retries on failed requests and has configurable timeouts.

=head1 Usage

To make a request, create an instance of the client and then call the get(), post(), put(), or delete() methods


	# Required parameters:
	my $client = REST::Consumer->new(
		host => 'service.somewhere.com',
		port => 80,
	);


	# Optional parameters:
	my $client = REST::Consumer->new(
		host       => 'service.somewhere.com',
		port       => 80,
		timeout    => 60, (default 10)
		retry      => 10, (default 3)
		verbose    => 1, (default 0)
		keep_alive => 1, (default 0)
		agent      => 'Service Monkey', (default REST-Consumer/$VERSION)
		auth => {
			type => 'basic',
			username => 'yep',
			password => 'nope',
		},
	);


=head1 Methods

=over

=item B<get> ( path => PATH, params => [] )

Send a GET request to the given path with the given arguments


	my $deserialized_result = $client->get(
		path => '/path/to/resource',
		params => {
			field => value,
			field2 => value2,
		},
	);


the 'params' arg can be a hash ref or array ref, depending on whether you need multiple instances of the same key

	my $deserialized_result = $client->get(
		path => '/path/to/resource',
		params => [
			field => value,
			field => value2,
			field => value3,
		]
	);




=item B<post> (path => PATH, params => [key => value, key => value], content => {...} )

Send a POST request with the given path, params, and content.  The content must be a data structure that can be serialized to JSON.

	# content is serialized to json by default
	my $deserialized_result = $client->post(
		path => '/path/to/resource',
		content => { field => value }
	);


	# if you don't want it serialized, specify another content type
	my $deserialized_result = $client->post(
		path => '/path/to/resource',
		content => { field => value }
		content_type => 'multipart/form-data',
	);

	# you can also specify headers if needed
	my $deserialized_result = $client->post(
		path => '/path/to/resource',
		headers => [
			'x-custom-header' => 'monkeys',	
		],
		content => { field => value }
	);


=item B<delete> (path => PATH, params => [])

Send a DELETE request to the given path with the given arguments

	my $result = $client->delete(
		path => '/path/to/resource',
		params => [
			field => value,
			field2 => value2,
		]
	);


=item B<get_response> (path => PATH, params => [key => value, key => value], headers => [key => value,....], content => {...}, method => METHOD )

Send a request with path, params, and content, using the specified method, and get a response object back  

	my $response_obj = $client->get_response(
		method => 'GET',
		path   => '/path/to/resource',
		headers => [
			'x-header' => 'header',
		],
		params => [
			field => value,
			field2 => value2,
		],
	);



=item B<get_processed_response> (path => PATH, params => [key => value, key => value], headers => [key => value,....], content => {...}, method => METHOD)

Send a request with path, params, and content, using the specified method, and get the deserialized content back

=item B<get_http_request> ( path => PATH, params => [PARAMS], headers => [HEADERS], content => [], method => '' )

get an HTTP::Request object for the given input

=back

=cut
