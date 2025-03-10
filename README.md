# MPU
A shim driver allows in-docker nvidia-smi showing correct process list without modify anything.

# Use in kubernetes

1. Deploy the mpu to your Kubernetes cluster.
```shell
$ helm install mpu oci://ghcr.io/lengrongfu/mpu --version 0.0.1
```

# The problems
The NVIDIA driver is not aware of the PID namespace and nvidia-smi has no capability to map global pid to virtual pid, thus it shows nothing.
What's more, The NVIDIA driver is proprietary and we have no idea what's going on inside even small part of the Linux NVIDIA driver is open sourced.

# The alternatives
- add 'hostPID: true' to the pod specification
- add '--pid=host' when starting a docker instance

# Installation
NOTE: kernel 5.7.7 build routines don't export kallsyms kernel functions any longer, which means this module may not work properly.

- for debian, to get kernel headers installed with `sudo apt install linux-headers-$(uname -r)`. run `sudo apt-get install build-essential` to get `make` toolset installed.
- clone this repo
- `cd` and `make`
- after build succeeded, `sudo make install` to install the module
- using docker to create `--gpu` enabled instance and run several cases and check process list via `nvidia-smi` to see if all associated processes have been correctly shown

# The steps
- figure out the basic mechanism of the NVIDIA driver with the open sourced part
- do some reverse engineering tests on the driver via GDB tools and several scripts (cuda/NVML)
- use our module to intercept syscalls and re-write fields of data strucuture with the knowledge of reverse engineering
- run the nvidia-smi with our module with several test cases

# The details
- nvidia-smi requests `0x20` ioctl command with `0xee4` flag to getting the global PID list (under `init_pid_ns`) **①**
- after getting non-empty PID list, it'll request `0x20` ioctl command with `0x1f48` flag with previous returned pids as input arguments to getting the process GPU memory consumptions **②**
- we hook the syscalls in system-wide approaching and intercept only NVIDIA device ioctl syscall (device major number is `195` and minor is `255` (control dev) which is defined in NVIDIA header file)
- check if request task is under any PID namespace, do nothing if it's global one (under `init_pid_ns`)
- if so, **①** convert the PID list from global to virtual
- however, **②** is a little more complicated which contains two-way interceptors--pre and post. 
  - on pre-stage, before invoking NVIDIA ioctl, the virtual PIDs (returned from **①**, converted) must convert back to global ones, since NVIDIA driver only recognize global PIDs. 
  - and one post-stage, after NVIDIA ioctl invoked, cast global PIDs back

---
![71614489144_ pic](https://user-images.githubusercontent.com/14119758/109408926-28831a00-79c9-11eb-8abf-a8382f5a897a.jpg)
---
![61614489023_ pic](https://user-images.githubusercontent.com/14119758/109408930-2d47ce00-79c9-11eb-8ec3-90f4324c6dd3.jpg)
---

# NOTE
tested on
- Ubuntu 20.04, kernel 5.4.0-153 x64, docker 28.0.1, NVIDIA driver 535.171.04
- Ubuntu 20.04, kernel 5.4.0-208 x64, docker 28.0.1, NVIDIA driver 550.135
- Ubuntu 22.04, kernel 5.15.0-125 x64, docker 27.5.0, NVIDIA driver 550.135
- Ubuntu 22.04, kernel 5.15.0-134 x64, docker 28.0.1, NVIDIA driver 550.135
- Ubuntu 24.04, kernel 6.8.0-55 x64, docker 28.0.1, NVIDIA driver 550.135
- Ubuntu 24.04, kernel 6.8.0-55 x64, docker 28.0.1, NVIDIA driver 570.124.04

---
Afterwords, we'd like to maintain the project with fully tested and more kernels and NVIDIA drivers supported. 
However we sincerely hope NVIDIA will fix this with simplicity and professionalism. Thx.
