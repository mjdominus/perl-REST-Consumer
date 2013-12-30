# REST::Consumer

A general-purpose client for interacting with RESTful HTTP services

### Synopsis

This module provides an interface that encapsulates building an http request, sending, and parsing responses.  It also retries on failed requests and has configurable timeouts.

### Usage

First configure the REST::Consumer class. This only needs to be done once per process and the results will be cached in a file. You can then refer to the service by name.

	REST::Consumer->configure('http://somewhere.com/consumer/config');

And / or:

	REST::Consumer->configure({
		'google-calendar' => {
			url => 'https://apps-apis.google.com',
		},
		'google-accounts' => {
			url => 'https://accounts.google.com',
		},
	});

Then later:

	my $media = REST::Consumer->service('google-calendar')->get(
		path => '/users/me/calendarList',
		timeout => 5,
		retry => 5,
	);

	use Data::Dumper;
	print Dumper($media);
