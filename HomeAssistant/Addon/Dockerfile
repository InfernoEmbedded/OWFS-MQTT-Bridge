ARG BUILD_FROM
FROM $BUILD_FROM

ENV LANG C.UTF-8

RUN apk add --no-cache gcc make autoconf libtool perl perl-utils git uthash coreutils
RUN mkdir -p /opt
RUN cd /tmp && \
	git clone --branch ie_cache_tweaks https://github.com/InfernoEmbedded/owfs.git && \
	cd /tmp/owfs && \
	./bootstrap && \
	./configure && \
	make -j `nproc` && \
	make install && \
	rm -rf /tmp/owfs
RUN apk del gcc make autoconf libtool uthash

RUN cd /opt && \
	git clone https://github.com/InfernoEmbedded/OWFS-MQTT-Bridge.git && \
	cd /opt/OWFS-MQTT-Bridge && \
