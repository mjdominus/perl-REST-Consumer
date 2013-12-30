package REST::Consumer::RequestException;

# an exception is always true
use overload bool => sub {1}, '""' => 'as_string', fallback => 1;

sub new {
	my ($class, %args) = @_;
	my $self = {
		request  => $args{request},
		response => $args{response},
		attempts => $args{attempts},
	};

	# get the immediate non-REST::Consumer caller
	# like Carp::croak for exception objects
	my ($package, $filename, $line) = caller;
	my $counter = 1;
	while ($package =~ /^REST::Consumer/) {
		($package, $filename, $line) = caller($counter++);
		last if $counter > 10;
	}

	$self->{_immediate_caller} = "$filename line $line";

	return bless $self, $class;
}

sub request { return shift->{request} }

sub response { return shift->{response} }

sub throw {
	my $class = shift;
	die $class->new(@_);
}

sub as_string {
	my $self = shift;
	my $attempts = $self->{attempts} ? " after $self->{attempts} attempts" : '';
	return sprintf("Request Failed$attempts: %s %s -- %s at %s\n",
		$self->{request}->method,
		$self->{request}->uri->as_string,
		$self->{response}->status_line,
		$self->{_immediate_caller},
	);
}

1;
