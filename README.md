(AKA "the thing that would be known as 'dockerstash' except I couldn't be
bothered arguing with Docker's lawyers over their ridiculous land-grab of a
trademark policy")

Mobystash is a tool to extract logs from a set of containers running under
Docke`^W`Moby and relay those logs in a reliable and observable manner to a
logstash server (or cluster of servers).  It uses appropriate
standards-based mechanisms to discover logstash servers, and prefers
reliability and correctness over the YOLOps approach taken by other similar
systems.


# Running

As you would expect from something that manages Docker containers, it is
available as a Docker image:

    docker run -v /var/run/docker.sock:/var/run/docker.sock \
        -e LOGSTASH_SERVER=192.0.2.42:5151 \
        discourse/mobystash

The `-v` option is required to allow the container to talk to the Moby daemon
to collect log entries, while the environment variables shown above are the
minimum configuration required (see "Configuration", below, for all valid
environment variables and their meaning).

Note that `mobystash` runs as UID 1000, with GIDs 1000 and 999.  The moby
daemon socket that you pass into the container must be readable and writable by
one of those IDs.

You can also run `mobystash` without a container, for testing or whatever
takes your fancy, as follows:

    LOGSTASH_SERVER=192.168.0.42:5151 \
    RUBYLIB=lib bin/mobystash


## Logstash server configuration

In order to have logstash receive the events we send, it needs to be
configured with a TCP socket using the `json_lines` codec.  Something like
this in your `logstash.conf` will do the trick:

    input {
      tcp {
        id    => "json_lines"
        port  => 5151
        codec => "json_lines"
      }
    }

To avoid the problem of duplicating log entries, particularly on restart,
mobystash generates a document ID which is tied to the specific content of
each log message.  If you configure your elasticsearch output plugin as
follows, you'll automatically get deduplication:

    output {
      elasticsearch {
        # ...
        document_id => "%{[@metadata][_id]}"
      }
    }


## Adaptive Sampling

Since logging systems can potentially generate large volumes of data very
quickly, it is useful to be able to keep the log volume under control by means
of *sampling*.  This involves only sending a small percentage of the log
entries that are received by `mobystash`, and dropping the rest on the floor.
To ensure you can reconstruct the underlying statistical data, the ratio at
which the log entries were sampled is recorded in the `mobystash.sample_ratio`
attribute (a decimal number) on each event that is sent.

The "*adaptive*" part of "adaptive sampling" means that you can define any
number of "sample keys" (regular expressions which match some subset of your
log entries), and the sample ratio of each key will be adjusted independently to
try and keep the total sample ratio close to a value you specify, whilst at the
same time ensuring that messages matching the less-frequently matched sample
keys are sent more often,so you'll still see them now and then.  For more
information on the rationale and mathematics behind this approach to sampling,
I would *strongly* recommend you read [this blog post from
Honeycomb](https://www.honeycomb.io/blog/instrumenting-high-volume-services-part-3/).

To configure adaptive sampling in `mobystash`, you need to do two things:

1. Define a target sample ratio, by setting the `MOBYSTASH_SAMPLE_RATIO`
   environment variable to a positive integer.  This defines how many log
   entries must be seen, on average, for one log entry to be sent to logstash.

2. Define one or more sample keys, by setting `MOBYSTASH_SAMPLE_KEY_<string>`
   environment variables to (Ruby-compatible) regular expressions.

What will happen now is that whenever a log entry comes in, the `message`
portion of the log entry (after any syslog parsing, if necessary) will be
matched against the unanchored regular expression defined in each sample key
environment variable.  The first regular expression that matches will associate
the log entry with the sample key corresponding to the regular expression that
matched.

> **NOTE**: the order in which regular expressions are matched is not defined,
> and no particular order is to be relied upon.  It is strongly recommended
> that you ensure that no log entry could match more than one regular
> expression, lest confusion reign.

Once a sample key is identified, the current calculated sample ratio for that
key will be used, along with random chance, to decide whether to send or drop
the log entry.  The sample key that matched the log entry will be included in
the entry under the `mobystash.sample_key` attribute, to help debugging and
general visibility.

If no regular expression matches the log entry, it will not be subjected to
sampling, and will be sent on.  In that case, the `mobystash.sample_ratio`
and `mobystash.sample_key` attributes will *not* be present on the log entry,
and you can use the Kibana "field absent" filter to find log entries that
were not associated with any sample key.

Because everything's better with metrics, each log entry that is sent or
dropped will be counted in either the `mobystash_sampled_entries_sent_total` or
`mobystash_sampled_entries_dropped_total` metric, labelled with the
`sample_key`.  Log entries that did not match a sample key will not be counted
in either of these metrics, and will instead be counted in
the (unlabelled) `mobystash_unsampled_entries_total` metric.  The current sample
ratio for each `metric_key` is available in the `mobystash_sample_ratio` gauge.

It is important to note that all sampling happens during initial event
processing, long before the log entries go into the queue to be sent to
logstash.  If the sending queue fills up, entries will be dropped in purely age
order, with no consideration for sample ratios.  Thus it is important to not let
your queues overflow if you want to maintain the statistical validity of your
data.


### Dynamic sample keys

Let's say you're processing HTTP access logs.  Each log entry contains a HTTP
response code, and you'd like to use that as your sample key, so that you get
your (many and frequent) `200 OK` down-sampled heavily, whilst your (hopefully
rare) 500 responses are all recorded.

You could, of course, sit down and define a regular expression for each HTTP
response code, and tie it to an individual sample key, but ain't *nobody* got
time for that.  Instead, you can capture portions of the message (surrounding
parts of the regular expression with parentheses), and then substitute those
into the sample key to generate the actual key via backreferences (`\N`, where
`N` is a digit between `1` and `9` inclusive -- yes, you can have a maximum of
nine backreferences).

As an example, if our HTTP access logs contained the HTTP response code tagged
with `rsp:`, as in `rsp:200` or `rsp:404`, and surrounded by spaces. You could
use the following environment variable definition:

    MOBYSTASH_SAMPLE_KEY_http_\1=" rsp:(\d{3}) "

When `mobystash` matches a log entry against that regular expression, the first
(and, in this case, only) capture -- the three digits matched by `\d{3}` --
will be substituted for the `\1` in the key name, to produce a sample key of,
say, `http_200` or `http_404`.  It is that string which will then be used to
aggregate log entry counts and determine the appropriate sample ratio.


# Configuration

All configuration of `mobystash` is done via environment variables.  The
recognised variables are listed below.


## Required Environment Variables

All of these environment variables must be set when `mobystash` is started,
otherwise the program will immediately exit with an error message.

* **`LOGSTASH_SERVER`**

    An IP address, hostname, or SRV record name identifyinging the logstash
    server(s) to send log events to.  IPv6 addresses can optionally be
    surrounded by square brackets.  Unless you're using SRV records, the
    TCP port to connect to must be given, separated from the address or
    hostname by a colon.  For more details of the valid formats, along with
    examples, see [the `LogstashWriter` usage
    documentation](https://github.com/discourse/logstash_writer#usage).


## Optional Environment Variables

The following environment variables are all optional, in that they have a
sensible default which works OK in at least some circumstances.

* **`MOBYSTASH_LOG_LEVEL`**

    *Default*: `"INFO"`

    Sets the degree of logging verbosity emitted by default from mobystash's
    operation.  Useful values are `"DEBUG"`, `"INFO"`, and `"ERROR"`.  See
    also the `USR1` and `USR2` signals, which can be used to change the log
    level at runtime.

* **`MOBYSTASH_DEBUG_MODULES`**

    *Default*: `""`

    This setting has no effect unless `MOBYSTASH_LOG_LEVEL=DEBUG`.

    If set to a non-empty string, this variable is interpreted as a
    comma-separated list of module names (as specified by the argument to
    `@logger.debug`) for which debug messages will be logged.  By default,
    all debug messages will be logged.

* **`MOBYSTASH_ENABLE_METRICS`**

    *Default*: `"false"`

    If set to a true-ish string (`"yes"`, `"true"`, `"on"`, or `"1"`), then
    a webserver will be started on port 9367, which will emit
    [Prometheus](https://prometheus.io/) metric data on `/metrics`.

* **`MOBYSTASH_SAMPLE_RATIO`**

    *Default*: `"1"`

    Sets the number of log entries that will be read, on average, in order for
    one log entry to be sent, as part of the adaptive sampling system.  This
    configuration variable will only be active if one or more sample keys are
    defined, via the `MOBYSTASH_SAMPLE_KEY_<string>` environment variable
    prefix.

    For more details, see the section "[Adaptive
    Sampling](#adaptive-sampling)", above.

* **`MOBYSTASH_SAMPLE_KEY_<string>`**

    Define a sample key, for use in mobystash's adaptive sampling system.  The
    `<string>` can be any non-empty string, and can include backreference
    specifiers `\1` to `\9`.  For more details, see the section "[Adaptive
    Sampling](#adaptive-sampling)", above.

* **`MOBYSTASH_STATE_CHECKPOINT_INTERVAL`**

    *Default: `"1"`

    The duration of time, in seconds, that will approximately elapse between
    updates to the state file, which keeps a record of the timestamp of the
    last log entry seen for each container.  The value can be any non-negative
    decimal number.  The smaller the interval, the fewer log entries will be
    duplicated after a crash, but the more disk I/O will be consumed.

* **`MOBYSTASH_STATE_FILE`**

    *Default: `"./mobystash_state.dump"`

    The state file contains the timestamp of the most recent log entry seen
    for each container being monitored.  This allows mobystash to resume
    logging where it left off after a restart.  It is recommended that you
    put this state file in a standalone volume, for persistence.

* **`DOCKER_HOST`**

    *Default*: `"unix:///var/run/docker.sock"`

    Where `mobystash` should connect in order to communicate with the Moby
    daemon.

    This is mostly useful in situations where you want to put your Moby
    socket somewhere unusual.  If you change the `-v` option you pass to
    `docker run` when starting this container, or you're connecting to
    Docker via TCP, you'll need to change this, otherwise you can leave it
    alone.


# Per-container Configuration

By default, `mobystash` will forward all logs from a container to logstash.
If you wish to opt-out of that logging, filter which logs are forwarded, or
provide additional fields to the logged events, you can [label your
containers](https://docs.docker.com/engine/userguide/labels-custom-metadata/)
as follows.


## Opt out of logging

Some containers provide their own ship-to-logstash functionality, and
provide a "convenience copy" of their log data to Docker.  To prevent
`mobystash` from sending duplicates of those log entries, containers can
label themselves to tell `mobystash` to not bother logging their output at
all, by setting the `org.discourse.mobystash.disable` label to a true-ish
value (one of `yes`, `1`, `true`, or `on` -- all case-insensitive), like
this:

    --label org.discourse.mobystash.disable=yes


## Filtering forwarded log entries

If you wish to only send a subset of the log entries to logstash, you can do
so by setting the `org.discourse.mobystash.filter_regex` label to a Ruby
regular expression.  Any log entry matching the pattern will ***not*** be
forwarded to logstash.  For example, to drop any log entry starting with
`DEBUG` or containing the string `wakkawakka`, you might set this on your
`docker run` command line:

    --label org.discourse.mobystash.filter_regex='\ADEBUG|wakkawakka'


## Parsing syslog messages

If a program in your container happens to be limited to using syslog as a
logging mechanism, mobystash has you covered!

First, you can cause all messages intended for syslog to instead be printed
to stderr by running something like this in your container, before you start
the main program:

    /usr/bin/socat UNIX-RECV:/dev/log,mode=0666 stderr &

Then, put the following label onto the container:

    --label org.discourse.mobystash.parse_syslog=yes

This will cause mobystash to parse all log messages which begin with the
syslog priority/facility specifier `<NN>` as syslog messages, and add a
`syslog` block of tags to the event sent to logstash.


## Tagging logstash events

Since logstash events are JSON objects, you can add arbitrary metadata to
them just by setting keys in the object.  Common tags are things like `_type`,
`hostname`, and so on.

To set a tag `<name>` on all logstash events generated from the container,
attach a label of the form `org.discourse.mobystash.tag.<name>`; for
example, to set `_type` to `applog`, you could use this `docker run`
command-line option:

    --label org.discourse.mobystash.tag.fred=jones

You can also set nested tags:

    --label org.discourse.mobystash.tag.something.funny=wombat

This will be transformed into a nested object, like so:

    {
      "something":
      {
        "funny": "wombat"
      }
    }

There are a number of pre-defined tags that every event sent to logstash will
include.  Any per-container tags you set via labels will override the
default values.  The pre-defined tags cannot be removed, only overridden.

* `moby.name` -- the name of the container that emitted the log entry.
* `moby.id` -- the full hex ID of the container that emitted the log
  entry.
* `moby.image` -- the "friendly" name of the image that underlies the
  container, as provided to `docker run`.
* `moby.image_id` -- the sha256 (or otherwise) ID of the image that
  underlies the container, derived from the friendly image name.
* `moby.hostname` -- the configured hostname of the container.
* `moby.stream` -- either `stdout` or `stderr`, depending on which stream
  the log entry was sent over.
* `@timestamp` -- the time at which the log entry was received by the Moby
  daemon.
* `@metadata.document_id` -- a string generated based on the contents of
  the log entry; this allows logstash/elasticsearch to de-duplicate log
  entries if required.
* `@metadata.event_type` -- set to "moby" by default; allows logstash to
  process and/or index these logs differently to others
* `message` -- the full message string provided in the log entry.


# Signals

The `mobystash` command-line program (and hence the Docker container) accept
the following signals to control the running service:

* **`USR1`**: Increase the verbosity of the logging output, `ERROR` ->
  `WARN` -> `INFO` -> `DEBUG`.

* **`USR2`**: Decrease the verbosity of logging, `DEBUG` -> `INFO` -> `WARN`
  -> `ERROR`.  Errors are always logged.

* **`TERM`** / **`INT`**: Terminate gracefully, waiting for all queued
  events to be sent to logstash before exiting.

* **`HUP`**: Disconnect from the currently-connected logstash server, and
  reconnect to a new server on the next log message received.


# Instrumentation

In keeping with modern best practices, `mobystash` can provide an extensive
set of metrics on its performance and operation.  To gain access to them,
you'll need to set the `MOBYSTASH_ENABLE_METRICS` environment variable to
`true`; once that's done, `mobystash` will listen on port 9367 for HTTP
requests to `/metrics`, and will respond with a Prometheus-compatible
response containing all of the metrics that have been collected.

Since the Prometheus format's built-in documentation capabilities are... 
limited, to say the least, all of the `mobystash` metrics and what they
represent are listed below.  In addition to those metrics listed below, the
metrics provided by
[`logstash_writer`](https://github.com/discourse/logstash_writer#prometheus-metrics)
and standard [Prometheus process
metrics](https://prometheus.io/docs/instrumenting/writing_clientlibs/#process-metrics)
are exposed.

* **`mobystash_moby_events_total`**: The number of events that have been emitted
  by the moby daemon while we've been watching, labelled by the type of event.

* **`mobystash_log_entries_read_total`**: A count of the number of log
  entries that have been received from the Moby daemon, labelled by
  container name (`name`), container ID (`container_id`), and whether the
  log entry came through stdout or stderr (`stream`).  Since containers that
  have been labelled as "disabled" for mobystash purposes don't read log
  entries, they shouldn't show up in here at all.

* **`mobystash_log_entries_sent_total`**: A count of the number of log
  entries that have been sent on to the LogstashWriter, labelled the same as
  `mobystash_log_entries_read_total`.  Differences between
  this counter and `mobystash_log_entries_read_total` can be caused by
  filtering and sampling (filtered and sampled log entries are counted by
  `read_total`, but not `sent_total`), log entries which failed to be processed
  (due to exception), or nasssssssty bugsssses.

* **`mobystash_moby_watch_exceptions_total`**: How many exceptions have been
  raised whilst polling the moby daemon looking for start/stop events. 
  Ideally, this counter will never be non-zero; if it is, you can find the
  exception details, including a backtrace, in the logs.

* **`mobystash_moby_read_exceptions_total`**: How many exceptions have been
  raised while reading log entries, labelled by the exception `class`,
  container name, and container ID.  This should never be a non-zero number,
  but if it is, the exception details, including a backtrace, should be in
  the logs.

* **`mobystash_sampled_entries_sent_total`**: How many sampled log entries
  have been sent on to logstash, labelled by the `metric_key` that matched
  the log entry.

* **`mobystash_sampled_entries_dropped_total`**: How many sampled log entres
  have been dropped (not sent on to logstash), labelled by the `metric_key`
  that matched the log entry.

* **`mobystash_sample_ratio`**: The current sample ratio being used to reduce
  the number of log entries sent to logstash, labelled by the `metric_key`.

* **`mobystash_unsampled_entries_total`**: How many log entries have gone
  through without being matched by any metric key.  Mostly useful if you
  *expect* all your log entries to match a metric key, in which case a
  non-zero value here would be worth investigating.


## HTTP metrics server

It's not a complete instrumentation package unless the metrics server
is spitting out metrics for itself.  Very meta.  Note that, since the metrics
are updated *after* a request is processed, it doesn't include the request that
retrieves the metrics you're looking at.

* **`mobystash_metrics_requests_total`**: How many requests have hit the metrics
  HTTP server.

* **`mobystash_metrics_request_duration_seconds_{bucket,sum,count}`**: [Histogram
  metrics](https://prometheus.io/docs/practices/histograms/) for the time
  taken to service HTTP metrics server requests.

* **`mobystash_metrics_exceptions_total`**: How many requests to the metrics
  server resulted in an unhandled exception being raised, labelled by
  exception class.  This should never have a non-zero number anywhere around
  it.


# Development

Please maintain 100% code/doc coverage and rubocop-enforced code style in all
changes.  Running `rake` will report rubocop offences and code/doc coverage
stats as well as running test suite.

Patches can be sent as [a Github pull
request](https://github.com/discourse/loggerstash).  This project is
intended to be a safe, welcoming space for collaboration, and contributors
are expected to adhere to the [Contributor Covenant code of
conduct](CODE_OF_CONDUCT.md).


## Deployment

The canonical distribution unit is the Moby container image.  Run `rake
docker:build` to make a local container for testing, and `rake
docker:publish` to build and push a container image to
`discourse/mobystash:latest`.


# Licence

Unless otherwise stated, everything in this repo is covered by the following
copyright notice:

    Copyright (C) 2018  Civilized Discourse Construction Kit, Inc.

    This program is free software: you can redistribute it and/or modify it
    under the terms of the GNU General Public License version 3, as
    published by the Free Software Foundation.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
