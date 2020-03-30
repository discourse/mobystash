FROM ruby:2.6.1-slim-stretch

MAINTAINER Matt Palmer "matt.palmer@discourse.org"

RUN useradd mobystash -s /bin/bash -m -U --create-home

COPY Gemfile Gemfile.lock mobystash.gemspec /home/mobystash/

ARG GIT_REVISION=invalid-build
ENV MOBYSTASH_GIT_REVISION=$GIT_REVISION

RUN DEBIAN_FRONTEND=noninteractive apt-get update \
	&& DEBIAN_FRONTEND=noninteractive apt-get -y dist-upgrade \
	&& DEBIAN_FRONTEND=noninteractive apt-get -y install --no-install-recommends \
		build-essential \
		libjemalloc-dev \
	&& docker_group="$(getent group 999 | cut -d : -f 1)" \
	&& if [ -z "$docker_group" ]; then groupadd --gid 999 docker; docker_group=docker; fi \
	&& addgroup mobystash "$docker_group" \
	&& cd /home/mobystash && su -l mobystash -c "bundle install --deployment --without development" \
	&& DEBIAN_FRONTEND=noninteractive apt-get -y purge \
		build-essential \
		linux-libc-dev \
	&& DEBIAN_FRONTEND=noninteractive apt-get -y --purge autoremove \
	&& DEBIAN_FRONTEND=noninteractive apt-get clean \
	&& ( find /var/lib/apt/lists -mindepth 1 -maxdepth 1 -delete || true ) \
	&& ( find /var/tmp -mindepth 1 -maxdepth 1 -delete || true ) \
	&& ( find /tmp -mindepth 1 -maxdepth 1 -delete || true )

COPY lib /home/mobystash/lib

COPY bin/* /usr/local/bin/

EXPOSE 9367
LABEL org.discourse.service._prom-exp.port=9367 org.discourse.service._prom-exp.instance=mobystash org.discourse.mobystash.disable=yes

USER mobystash
WORKDIR /home/mobystash

ENV LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so

# docker is just confusing me so much here, no ideal what is changing... something ...
# this writes some file somewhere or changes a permission, but I do not know what
# without this /usr/local/bin/mobystash no worky
RUN bundle install --deployment --without development

ENTRYPOINT ["/usr/local/bin/bundle", "exec", "/usr/local/bin/mobystash"]
