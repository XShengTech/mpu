//  MPU, A shim driver allows in-docker nvidia-smi showing correct process list without modify anything
//  Copyright (C) 2021, Matpool
//
//  This program is free software; you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation; either version 2 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/version.h>
#include <linux/ftrace.h>
#include <linux/kprobes.h>
#include <linux/fs.h>
#include <linux/uaccess.h>
#include <linux/syscalls.h>

static char saved_syscall_name[64];

// 定义所需结构体和类型
typedef struct mpu_ioctl_call
{
  unsigned int fd;
  unsigned int cmd;
  unsigned long arg;
} mpu_ioctl_call_t;

typedef struct mpu_ctx
{
  void *private_data;
} mpu_ctx_t;

typedef struct mpu_module
{
  long (*ioctl)(mpu_ctx_t *ctx, mpu_ioctl_call_t *call, dev_t dev);
} mpu_module_t;

typedef struct mpu_hook_instance
{
  mpu_module_t *module;
  mpu_ctx_t *ctx;
} mpu_hook_instance_t;

#ifdef CONFIG_ARCH_HAS_SYSCALL_WRAPPER
typedef long (*ioctl_fn)(const struct pt_regs *);
#else
typedef long (*ioctl_fn)(unsigned int, unsigned int, unsigned long);
#endif

typedef struct mpu_ioctl_private
{
  mpu_ioctl_call_t c;
  ioctl_fn ioctl;
  const struct pt_regs *regs;
} mpu_ioctl_private_t;

// 全局变量
static ioctl_fn orig_sys_ioctl;
static mpu_hook_instance_t mpu_hook_instance;

// 获取文件描述符对应的设备号
static dev_t get_rdev(unsigned int fd)
{
  struct fd f = fdget(fd);
  dev_t dev = 0;

  if (!f.file)
    return 0;

  if (f.file->f_inode)
    dev = f.file->f_inode->i_rdev;

  fdput(f);
  return dev;
}

// ftrace 回调函数和相关结构
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 11, 0)
#ifndef FTRACE_OPS_FL_RECURSION_SAFE
// 如果 RECURSION_SAFE 不存在，就使用原始的 RECURSION 标志
#define FTRACE_OPS_FL_RECURSION_SAFE FTRACE_OPS_FL_RECURSION
#else
#define FTRACE_OPS_FL_RECURSION FTRACE_OPS_FL_RECURSION_SAFE
#endif
#endif

#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 7, 0)
static unsigned long lookup_name(const char *name)
{
  struct kprobe kp = {
      .symbol_name = name};
  unsigned long retval;

  if (register_kprobe(&kp) < 0)
    return 0;
  retval = (unsigned long)kp.addr;
  unregister_kprobe(&kp);
  return retval;
}
#else
static unsigned long lookup_name(const char *name)
{
  return kallsyms_lookup_name(name);
}
#endif

static struct ftrace_hook
{
  const char *name;
  void *function;
  void *original;
  unsigned long address;
  struct ftrace_ops ops;
} ioctl_hook;

static int fh_resolve_hook_address(struct ftrace_hook *hook)
{
  hook->address = lookup_name(hook->name);
  if (!hook->address)
  {
    pr_err("未找到函数: %s\n", hook->name);
    return -ENOENT;
  }
  *((unsigned long *)hook->original) = hook->address;
  return 0;
}

#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 11, 0)
static void notrace fh_ftrace_thunk(unsigned long ip, unsigned long parent_ip,
                                    struct ftrace_ops *ops, struct ftrace_regs *fregs)
{
  struct ftrace_hook *hook = container_of(ops, struct ftrace_hook, ops);
  struct pt_regs *regs = ftrace_get_regs(fregs);

  if (!within_module(parent_ip, THIS_MODULE))
    regs->ip = (unsigned long)hook->function;
}
#else
static void notrace fh_ftrace_thunk(unsigned long ip, unsigned long parent_ip,
                                    struct ftrace_ops *ops, struct pt_regs *regs)
{
  struct ftrace_hook *hook = container_of(ops, struct ftrace_hook, ops);

  if (!within_module(parent_ip, THIS_MODULE))
    regs->ip = (unsigned long)hook->function;
}
#endif

static int fh_install_hook(struct ftrace_hook *hook)
{
    int err;
    
    err = fh_resolve_hook_address(hook);
    if (err)
        return err;
        
    hook->ops.func = fh_ftrace_thunk;
    hook->ops.flags = FTRACE_OPS_FL_SAVE_REGS
                    | FTRACE_OPS_FL_RECURSION  // 使用标准的宏，不尝试重定义
                    | FTRACE_OPS_FL_IPMODIFY;
                    
    err = ftrace_set_filter_ip(&hook->ops, hook->address, 0, 0);
    if (err) {
        pr_err("ftrace_set_filter_ip() failed: %d\n", err);
        return err;
    }
    
    err = register_ftrace_function(&hook->ops);
    if (err) {
        pr_err("register_ftrace_function() failed: %d\n", err);
        ftrace_set_filter_ip(&hook->ops, hook->address, 1, 0);
        return err;
    }
    
    return 0;
}

static void fh_remove_hook(struct ftrace_hook *hook)
{
  int err;

  err = unregister_ftrace_function(&hook->ops);
  if (err)
    pr_err("unregister_ftrace_function() failed: %d\n", err);

  err = ftrace_set_filter_ip(&hook->ops, hook->address, 1, 0);
  if (err)
    pr_err("ftrace_set_filter_ip() failed: %d\n", err);
}

// 系统调用钩子函数
#ifdef CONFIG_ARCH_HAS_SYSCALL_WRAPPER
static asmlinkage long mpu_hooked_ioctl(const struct pt_regs *regs)
{
  mpu_ioctl_private_t pc = {
      .c = {
          .fd = (unsigned int)regs->di,
          .cmd = (unsigned int)regs->si,
          .arg = (unsigned long)regs->dx,
      },
      .ioctl = orig_sys_ioctl,
      .regs = regs,
  };
  dev_t dev = get_rdev(pc.c.fd);
  return mpu_hook_instance.module->ioctl(mpu_hook_instance.ctx, &pc.c, dev);
}

long mpu_call_ioctl(mpu_ioctl_call_t *c)
{
  mpu_ioctl_private_t *pc = container_of(c, mpu_ioctl_private_t, c);
  return pc->ioctl(pc->regs);
}
#else
static asmlinkage long mpu_hooked_ioctl(unsigned int fd, unsigned int cmd, unsigned long arg)
{
  mpu_ioctl_private_t pc = {
      .c = {
          .fd = fd,
          .cmd = cmd,
          .arg = arg,
      },
      .ioctl = orig_sys_ioctl,
  };
  dev_t dev = get_rdev(fd);
  return mpu_hook_instance.module->ioctl(mpu_hook_instance.ctx, &pc.c, dev);
}

long mpu_call_ioctl(mpu_ioctl_call_t *c)
{
  mpu_ioctl_private_t *pc = container_of(c, mpu_ioctl_private_t, c);
  return pc->ioctl(c->fd, c->cmd, c->arg);
}
#endif

// 添加一个查找系统调用的函数
static int find_syscall(struct ftrace_hook *hook, const char *base_name)
{
  const char *prefixes[] = {
    "__x64_sys_",  // x86_64 Linux 4.17+
    "__ia32_sys_", // ia32 兼容性
    "__se_sys_",   // 安全模式
    "__do_sys_",   // 某些内部封装
    "sys_",        // 传统命名
    NULL
  };
  int i;
  
  for (i = 0; prefixes[i] != NULL; i++) {
    // 使用全局变量保存系统调用名称
    snprintf(saved_syscall_name, sizeof(saved_syscall_name), "%s%s", prefixes[i], base_name);
    hook->name = saved_syscall_name;
    hook->address = lookup_name(hook->name);
    
    if (hook->address) {
      *((unsigned long*)hook->original) = hook->address;
      pr_info("mpu: 找到系统调用: %s @ 0x%lx\n", hook->name, hook->address);
      return 0;
    }
  }
  
  pr_err("mpu: 无法找到任何 %s 系统调用变体\n", base_name);
  return -ENOENT;
}

int mpu_init_ioctl_hook(mpu_module_t *module, mpu_ctx_t *ctx)
{
  int ret;

  if (!module || !module->ioctl || !ctx)
  {
    return -EINVAL;
  }

  // 清空并初始化 hook 结构体
  memset(&ioctl_hook, 0, sizeof(ioctl_hook));
  
  mpu_hook_instance.module = module;
  mpu_hook_instance.ctx = ctx;
  
  // 设置 ftrace 钩子
  ioctl_hook.function = mpu_hooked_ioctl;
  ioctl_hook.original = &orig_sys_ioctl;

  // 寻找正确的系统调用
  ret = find_syscall(&ioctl_hook, "ioctl");
  if (ret) {
    pr_err("mpu: 找不到 ioctl 系统调用\n");
    return ret;
  }

  ret = fh_install_hook(&ioctl_hook);
  if (ret) {
    pr_err("mpu: 安装 ioctl 钩子失败: %d\n", ret);
    return ret;
  }

  pr_info("mpu: 系统调用钩子已成功安装\n");
  return 0;
}

void mpu_exit_ioctl_hook(void)
{
  fh_remove_hook(&ioctl_hook);
  pr_info("mpu: 系统调用钩子已移除\n");
}