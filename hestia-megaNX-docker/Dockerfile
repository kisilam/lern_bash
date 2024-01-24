FROM ubuntu:18.04

RUN apt update;  \
    apt upgrade -y;  \
    apt install -y  build-essential; \
    apt install -y  git \
                    autoconf \
                    libtool \
                    g++ \
                    libcrypto++-dev \
                    libz-dev \ 
                    libsqlite3-dev \
                    libssl-dev \
                    libcurl4-gnutls-dev \
                    libreadline-dev \
                    libpcre++-dev \
                    libsodium-dev \
                    libc-ares-dev \
                    libfreeimage-dev \
                    libavcodec-dev \
                    libavutil-dev \
                    libavformat-dev \
                    libswscale-dev \
                    libmediainfo-dev \
                    libzen-dev \
                    libuv1-dev; \
    rm -rf /var/lib/apt/lists/*;

WORKDIR /opt

RUN git clone https://github.com/meganz/MEGAcmd.git \
    && cd MEGAcmd && git submodule update --init --recursive \
    && sh autogen.sh \
    && ./configure \
    && make \
    && make install \
    && cd .. && rm -rf MEGAcmd \
    && ldconfig

ENV PATH="$PATH:/usr/local/lib"

CMD ["/bin/bash"]
