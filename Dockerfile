FROM ubuntu:18.04

RUN apt-get update && apt-get install -y wget gcc-aarch64-linux-gnu git build-essential bison flex bc u-boot-tools python3

RUN git config --global user.email "docker.root@example.com"
RUN  git config --global user.name "Docker Root"


COPY build-uboot.sh /usr/local/bin/
COPY patches/* /work/patches/

COPY docker-entrypoint.sh /usr/local/bin/

WORKDIR /work
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
