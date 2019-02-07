FROM ruby:2.5-alpine

MAINTAINER Matt Palmer "matt.palmer@discourse.org"

COPY Gemfile Gemfile.lock /home/mobystash/

RUN adduser -D mobystash \
	&& docker_group="$(getent group 999 | cut -d : -f 1)" \
	&& if [ -z "$docker_group" ]; then addgroup -g 999 docker; docker_group=docker; fi \
	&& addgroup mobystash "$docker_group" \
	&& apk update \
	&& apk add build-base \
	&& cd /home/mobystash \
	&& su -pc 'bundle install --deployment --without development' mobystash \
	&& apk del build-base \
	&& rm -rf /tmp/* /var/cache/apk/*

ARG GIT_REVISION=invalid-build
ENV MOBYSTASH_GIT_REVISION=$GIT_REVISION

COPY bin/* /usr/local/bin/
COPY lib/ /usr/local/lib/ruby/2.5.0/

EXPOSE 9367
LABEL org.discourse.service._prom-exp.port=9367 org.discourse.service._prom-exp.instance=mobystash org.discourse.mobystash.disable=yes

USER mobystash
WORKDIR /home/mobystash
ENTRYPOINT ["/usr/local/bin/bundle", "exec", "/usr/local/bin/mobystash"]
