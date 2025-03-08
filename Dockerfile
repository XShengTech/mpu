FROM ubuntu:22.04 AS build
WORKDIR /mpu
COPY . /mpu
RUN apt-get update && apt-get install -y build-essential && apt-get install -y linux-headers-$(uname -r)
RUN make

FROM ubuntu:22.04 AS run
WORKDIR /mpu
COPY --from=build /mpu/mpu.ko /mpu
COPY --from=build /mpu/Makefile /mpu
RUN apt-get update && apt-get install -y kmod
CMD ["/bin/sh", "-c", "bash run.sh install && sleep infinity"]