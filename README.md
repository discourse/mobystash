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
default values.  The pre-defined tags cannot be removed, only modified.

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
* `@metadata._id` -- a pseudorandom identifying string; this allows
  logstash/elasticsearch to de-duplicate log entries if required.
* `@metadata._type` -- set to "moby" by default; allows logstash to process
  and/or index these logs differently to others
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
  filtering (filtered log entries are counted by `read_total`, but not
  `sent_total`), log entries which failed to be processed (due to
  exception), or nasssssssty bugsssses.

* **`mobystash_moby_watch_exceptions_total`**: How many exceptions have been
  raised whilst polling the moby daemon looking for start/stop events. 
  Ideally, this counter will never be non-zero; if it is, you can find the
  exception details, including a backtrace, in the logs.

* **`mobystash_moby_read_exceptions_total`**: How many exceptions have been
  raised while reading log entries, labelled by the exception `class`,
  container name, and container ID.  This should never be a non-zero number,
  but if it is, the exception details, including a backtrace, should be in
  the logs.


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
