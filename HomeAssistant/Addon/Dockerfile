ARG BUILD_FROM
FROM $BUILD_FROM

ENV LANG C.UTF-8

RUN apk add --no-cache gcc make autoconf automake libtool perl perl-utils git uthash-dev coreutils musl-dev curl wget perl-app-cpanminus jq
RUN mkdir -p /opt
RUN cd /tmp && \
	git clone --branch ie_cache_tweaks https://github.com/InfernoEmbedded/owfs.git && \
	cd /tmp/owfs && \
	./bootstrap && \
	./configure --enable-uthash --disable-w1 && \
	make -j `nproc` && \
	make install && \
	rm -rf /tmp/owfs

RUN cpanm -n -v AnyEvent AnyEvent::AIO AnyEvent::MQTT AnyEvent::OWNet DateTime::Format::Strptime ExtUtils::MakeMaker \
		File::Slurp JSON::Parse Test::Most TOML 

RUN cd /opt && \
	git clone -b hassio https://github.com/InfernoEmbedded/OWFS-MQTT-Bridge.git

RUN apk del gcc make autoconf automake libtool uthash-dev
RUN rm -rf /root/.cpanm/work

COPY run.sh /
RUN chmod a+x /run.sh

CMD [ "/run.sh" ]
