FROM ubuntu:20.04 AS build
WORKDIR /mpu
COPY . /mpu
#RUN apt-get update && apt-get install -y build-essential && apt-get install -y linux-headers-$(uname -r)
#RUN make
CMD ["/bin/sh", "-c", "bash run.sh install && sleep infinity"]

#FROM ubuntu:20.04 AS run
#WORKDIR /mpu
#COPY --from=build /mpu/mpu.ko /mpu
#COPY --from=build /mpu/run.sh /mpu
#RUN apt-get update && apt-get install -y kmod
#CMD ["/bin/sh", "-c", "bash run.sh install && sleep infinity"]