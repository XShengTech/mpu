obj-m += mpu.o
mpu-objs := src/mpu_drv.o src/mpu_syscall_hook.o src/mpu_ioctl.o

KVERSION := $(shell uname -r)
KDIR := /lib/modules/$(KVERSION)/build
PWD := $(shell pwd)

REGISTRY := ghcr.io
REGISTRY_PATH := lengrongfu/mpu
IMAGE_VERSION  ?= $(shell git describe --tags --dirty 2> /dev/null || git rev-parse --short HEAD)

default:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

install:
	insmod mpu.ko
	echo mpu > /etc/modules-load.d/matpool-mpu.conf

uninstall:
	rmmod mpu.ko
	rm /etc/modules-load.d/matpool-mpu.conf

images:
	docker build -t $(REGISTRY)/$(REGISTRY_PATH):$(IMAGE_VERSION) -f Dockerfile .