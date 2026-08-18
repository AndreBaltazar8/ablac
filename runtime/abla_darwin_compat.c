#define _DARWIN_C_SOURCE

// Abla exposes one stable Linux-style syscall surface to its portable hosted
// standard library. Darwin does not share Linux syscall numbers, socket
// layouts, or epoll, so Mach-O programs link this deliberately small adapter.
// It returns Linux-style negative errno values and contains no Abla runtime.

#include <arpa/inet.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

static int linux_errno(int value) {
  switch (value) {
  case EAGAIN:
    return 11;
  case EINPROGRESS:
    return 115;
  case EALREADY:
    return 114;
  case ENOSYS:
    return 38;
  case EADDRINUSE:
    return 98;
  case EAFNOSUPPORT:
    return 97;
  case ENETUNREACH:
    return 101;
  case ECONNRESET:
    return 104;
  case ENOTCONN:
    return 107;
  case ETIMEDOUT:
    return 110;
  case ECONNREFUSED:
    return 111;
  case EHOSTUNREACH:
    return 113;
  default:
    break;
  }
  return value;
}

static int darwin_open_flags(int64_t flags) {
  int result = 0;
  if ((flags & 3) == 1)
    result |= O_WRONLY;
  if ((flags & 3) == 2)
    result |= O_RDWR;
  if ((flags & 64) != 0)
    result |= O_CREAT;
  if ((flags & 128) != 0)
    result |= O_EXCL;
  if ((flags & 512) != 0)
    result |= O_TRUNC;
  if ((flags & 1024) != 0)
    result |= O_APPEND;
  if ((flags & 2048) != 0)
    result |= O_NONBLOCK;
  if ((flags & 65536) != 0)
    result |= O_DIRECTORY;
  if ((flags & 524288) != 0)
    result |= O_CLOEXEC;
  return result;
}

static int darwin_socket_type(int64_t type) {
  int result = (int)(type & 15);
  if (result == 1)
    result = SOCK_STREAM;
  if (result == 2)
    result = SOCK_DGRAM;
  return result;
}

static int darwin_socket_domain(int64_t domain) {
  if (domain == 2)
    return AF_INET;
  if (domain == 10)
    return AF_INET6;
  return (int)domain;
}

static void configure_descriptor(int descriptor, int64_t flags) {
  if (descriptor < 0)
    return;
  const int no_signal = 1;
  (void)setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &no_signal,
                   sizeof(no_signal));
  if ((flags & 524288) != 0)
    (void)fcntl(descriptor, F_SETFD, FD_CLOEXEC);
  if ((flags & 2048) != 0) {
    const int current = fcntl(descriptor, F_GETFL, 0);
    if (current >= 0)
      (void)fcntl(descriptor, F_SETFL, current | O_NONBLOCK);
  }
}

static int darwin_message_flags(int64_t flags) {
  // Darwin uses SO_NOSIGPIPE rather than Linux MSG_NOSIGNAL (0x4000).
  return (int)(flags & ~INT64_C(16384));
}

static long darwin_ioctl(int descriptor, int64_t request, void *argument) {
  if (request == 21505) {
    struct termios attributes;
    const int result = tcgetattr(descriptor, &attributes);
    if (result == 0 && argument != NULL) {
      uint32_t flags = (uint32_t)attributes.c_lflag;
      memcpy((unsigned char *)argument + 12, &flags, sizeof(flags));
    }
    return result;
  }
  if (request == 21506) {
    struct termios attributes;
    int result = tcgetattr(descriptor, &attributes);
    if (result == 0 && argument != NULL) {
      uint32_t flags = 0;
      memcpy(&flags, (unsigned char *)argument + 12, sizeof(flags));
      attributes.c_lflag = (tcflag_t)flags;
      result = tcsetattr(descriptor, TCSANOW, &attributes);
    }
    return result;
  }
  return ioctl(descriptor, (unsigned long)request, argument);
}

static void store_i64(unsigned char *output, size_t offset, int64_t value) {
  memcpy(output + offset, &value, sizeof(value));
}

static void store_u32(unsigned char *output, size_t offset, uint32_t value) {
  memcpy(output + offset, &value, sizeof(value));
}

static void store_u16(unsigned char *output, size_t offset, uint16_t value) {
  memcpy(output + offset, &value, sizeof(value));
}

static int darwin_sockaddr(const void *linux_address, size_t linux_length,
                           struct sockaddr_storage *output,
                           socklen_t *output_length) {
  if (linux_address == NULL || linux_length < 8) {
    errno = EINVAL;
    return -1;
  }
  const unsigned char *input = (const unsigned char *)linux_address;
  memset(output, 0, sizeof(*output));
  if (input[0] == 2 && input[1] == 0 && linux_length >= 16) {
    struct sockaddr_in *address = (struct sockaddr_in *)output;
    address->sin_len = (uint8_t)sizeof(*address);
    address->sin_family = AF_INET;
    memcpy(&address->sin_port, input + 2, 2);
    memcpy(&address->sin_addr, input + 4, 4);
    *output_length = (socklen_t)sizeof(*address);
    return 0;
  }
  if (input[0] == 10 && input[1] == 0 && linux_length >= 28) {
    struct sockaddr_in6 *address = (struct sockaddr_in6 *)output;
    address->sin6_len = (uint8_t)sizeof(*address);
    address->sin6_family = AF_INET6;
    memcpy(&address->sin6_port, input + 2, 2);
    memcpy(&address->sin6_flowinfo, input + 4, 4);
    memcpy(&address->sin6_addr, input + 8, 16);
    memcpy(&address->sin6_scope_id, input + 24, 4);
    *output_length = (socklen_t)sizeof(*address);
    return 0;
  }
  errno = EAFNOSUPPORT;
  return -1;
}

static int linux_sockaddr(const struct sockaddr *address,
                          socklen_t address_length, void *linux_address,
                          uint32_t *linux_length) {
  if (linux_address == NULL || linux_length == NULL)
    return 0;
  unsigned char *output = (unsigned char *)linux_address;
  if (address->sa_family == AF_INET &&
      address_length >= sizeof(struct sockaddr_in)) {
    if (*linux_length < 16) {
      errno = EINVAL;
      return -1;
    }
    const struct sockaddr_in *input = (const struct sockaddr_in *)address;
    memset(output, 0, 16);
    output[0] = 2;
    memcpy(output + 2, &input->sin_port, 2);
    memcpy(output + 4, &input->sin_addr, 4);
    *linux_length = 16;
    return 0;
  }
  if (address->sa_family == AF_INET6 &&
      address_length >= sizeof(struct sockaddr_in6)) {
    if (*linux_length < 28) {
      errno = EINVAL;
      return -1;
    }
    const struct sockaddr_in6 *input = (const struct sockaddr_in6 *)address;
    memset(output, 0, 28);
    output[0] = 10;
    memcpy(output + 2, &input->sin6_port, 2);
    memcpy(output + 4, &input->sin6_flowinfo, 4);
    memcpy(output + 8, &input->sin6_addr, 16);
    memcpy(output + 24, &input->sin6_scope_id, 4);
    *linux_length = 28;
    return 0;
  }
  errno = EAFNOSUPPORT;
  return -1;
}

static long darwin_getdents(int descriptor, unsigned char *output,
                            size_t capacity) {
  if (output == NULL || capacity < 24) {
    errno = EINVAL;
    return -1;
  }
  unsigned char *native = (unsigned char *)malloc(capacity);
  if (native == NULL) {
    errno = ENOMEM;
    return -1;
  }
  off_t base = 0;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  const long measured =
      syscall(SYS_getdirentries64, descriptor, native, capacity, &base);
#pragma clang diagnostic pop
  if (measured <= 0) {
    free(native);
    return measured;
  }
  size_t input_offset = 0;
  size_t output_offset = 0;
  while (input_offset < (size_t)measured) {
    const struct dirent *entry = (const struct dirent *)(native + input_offset);
    if (entry->d_reclen == 0 ||
        input_offset + entry->d_reclen > (size_t)measured) {
      free(native);
      errno = EIO;
      return -1;
    }
    const size_t name_length = strlen(entry->d_name);
    const size_t record_length = (19 + name_length + 1 + 7) & ~(size_t)7;
    if (record_length > UINT16_MAX ||
        output_offset + record_length > capacity) {
      free(native);
      errno = EOVERFLOW;
      return -1;
    }
    memset(output + output_offset, 0, record_length);
    store_i64(output, output_offset, (int64_t)entry->d_ino);
    store_i64(output, output_offset + 8, (int64_t)base);
    store_u16(output, output_offset + 16, (uint16_t)record_length);
    output[output_offset + 18] = entry->d_type;
    memcpy(output + output_offset + 19, entry->d_name, name_length + 1);
    output_offset += record_length;
    input_offset += entry->d_reclen;
  }
  free(native);
  return (long)output_offset;
}

static int darwin_socket_level(int level) {
  return level == 1 ? SOL_SOCKET : level;
}

static int darwin_socket_option(int level, int option) {
  if (level == SOL_SOCKET && option == 2)
    return SO_REUSEADDR;
  if (level == SOL_SOCKET && option == 4)
    return SO_ERROR;
  if (level == SOL_SOCKET && option == 15)
    return SO_REUSEPORT;
  if (level == IPPROTO_IPV6 && option == 26)
    return IPV6_V6ONLY;
  return option;
}

static long darwin_epoll_control(int descriptor, int operation, int target,
                                 const void *encoded) {
  if (encoded == NULL && operation != 2) {
    errno = EINVAL;
    return -1;
  }
  uint32_t events = 0;
  if (encoded != NULL)
    memcpy(&events, encoded, sizeof(events));
  struct kevent changes[4];
  int count = 0;
  if (operation == 3) {
    EV_SET(&changes[0], target, EVFILT_READ, EV_DELETE, 0, 0, NULL);
    EV_SET(&changes[1], target, EVFILT_WRITE, EV_DELETE, 0, 0, NULL);
    (void)kevent(descriptor, changes, 2, NULL, 0, NULL);
    count = 0;
  }
  const uint16_t flags = operation == 2 ? EV_DELETE : EV_ADD | EV_ENABLE;
  if ((events & 1) != 0 || operation == 2)
    EV_SET(&changes[count++], target, EVFILT_READ, flags, 0, 0,
           (void *)(intptr_t)target);
  if ((events & 4) != 0 || operation == 2)
    EV_SET(&changes[count++], target, EVFILT_WRITE, flags, 0, 0,
           (void *)(intptr_t)target);
  int result = kevent(descriptor, changes, count, NULL, 0, NULL);
  if (result == -1 && operation == 2 && errno == ENOENT)
    result = 0;
  return result;
}

static long darwin_epoll_wait(int descriptor, unsigned char *output,
                              int maximum, int timeout) {
  if (output == NULL || maximum <= 0) {
    errno = EINVAL;
    return -1;
  }
  struct kevent *events = calloc((size_t)maximum, sizeof(*events));
  if (events == NULL) {
    errno = ENOMEM;
    return -1;
  }
  const struct timespec duration = {.tv_sec = timeout / 1000,
                                    .tv_nsec = (timeout % 1000) * 1000000};
  int measured;
  do {
    measured = kevent(descriptor, NULL, 0, events, maximum,
                      timeout < 0 ? NULL : &duration);
  } while (measured < 0 && errno == EINTR);
  for (int index = 0; index < measured; ++index) {
    uint32_t flags = 0;
    if (events[index].filter == EVFILT_READ)
      flags |= 1;
    if (events[index].filter == EVFILT_WRITE)
      flags |= 4;
    if ((events[index].flags & EV_EOF) != 0)
      flags |= 16;
    if ((events[index].flags & EV_ERROR) != 0)
      flags |= 8;
    store_u32(output, (size_t)index * 12, flags);
    store_u32(output, (size_t)index * 12 + 4,
              (uint32_t)(uintptr_t)events[index].udata);
    store_u32(output, (size_t)index * 12 + 8, 0);
  }
  free(events);
  return measured;
}

int64_t abla_darwin_linux_syscall(int64_t number, int64_t argument0,
                                  int64_t argument1, int64_t argument2,
                                  int64_t argument3, int64_t argument4,
                                  int64_t argument5) {
  long result = -1;
  switch (number) {
  case 0:
    result =
        read((int)argument0, (void *)(uintptr_t)argument1, (size_t)argument2);
    break;
  case 1:
    result = write((int)argument0, (const void *)(uintptr_t)argument1,
                   (size_t)argument2);
    break;
  case 3:
    result = close((int)argument0);
    break;
  case 7:
    result = poll((struct pollfd *)(uintptr_t)argument0, (nfds_t)argument1,
                  (int)argument2);
    break;
  case 14:
  case 289:
    errno = ENOSYS;
    break;
  case 16:
    result =
        darwin_ioctl((int)argument0, argument1, (void *)(uintptr_t)argument2);
    break;
  case 21:
    result = access((const char *)(uintptr_t)argument0, (int)argument1);
    break;
  case 33:
    result = dup2((int)argument0, (int)argument1);
    break;
  case 35:
    result = nanosleep((const struct timespec *)(uintptr_t)argument0,
                       (struct timespec *)(uintptr_t)argument1);
    break;
  case 39:
    result = getpid();
    break;
  case 41: {
    const int descriptor =
        socket(darwin_socket_domain(argument0), darwin_socket_type(argument1),
               (int)argument2);
    configure_descriptor(descriptor, argument1);
    result = descriptor;
    break;
  }
  case 42:
  case 49: {
    struct sockaddr_storage address;
    socklen_t length = 0;
    if (darwin_sockaddr((const void *)(uintptr_t)argument1, (size_t)argument2,
                        &address, &length) == 0)
      result = number == 42 ? connect((int)argument0,
                                      (const struct sockaddr *)&address, length)
                            : bind((int)argument0,
                                   (const struct sockaddr *)&address, length);
    break;
  }
  case 44: {
    if (argument4 != 0 && argument5 > 0) {
      struct sockaddr_storage address;
      socklen_t length = 0;
      if (darwin_sockaddr((const void *)(uintptr_t)argument4, (size_t)argument5,
                          &address, &length) == 0)
        result = sendto((int)argument0, (const void *)(uintptr_t)argument1,
                        (size_t)argument2, darwin_message_flags(argument3),
                        (const struct sockaddr *)&address, length);
    } else
      result = send((int)argument0, (const void *)(uintptr_t)argument1,
                    (size_t)argument2, darwin_message_flags(argument3));
    break;
  }
  case 45: {
    struct sockaddr_storage address;
    socklen_t length = sizeof(address);
    result = recvfrom((int)argument0, (void *)(uintptr_t)argument1,
                      (size_t)argument2, (int)argument3,
                      argument4 == 0 ? NULL : (struct sockaddr *)&address,
                      argument4 == 0 ? NULL : &length);
    if (result >= 0 && argument4 != 0 &&
        linux_sockaddr((const struct sockaddr *)&address, length,
                       (void *)(uintptr_t)argument4,
                       (uint32_t *)(uintptr_t)argument5) != 0)
      result = -1;
    break;
  }
  case 46: {
    const unsigned char *encoded = (const unsigned char *)(uintptr_t)argument1;
    if (encoded == NULL) {
      errno = EINVAL;
      break;
    }
    uint64_t name = 0;
    uint32_t name_length = 0;
    uint64_t vectors = 0;
    uint64_t vector_count = 0;
    uint64_t control = 0;
    uint64_t control_length = 0;
    memcpy(&name, encoded, sizeof(name));
    memcpy(&name_length, encoded + 8, sizeof(name_length));
    memcpy(&vectors, encoded + 16, sizeof(vectors));
    memcpy(&vector_count, encoded + 24, sizeof(vector_count));
    memcpy(&control, encoded + 32, sizeof(control));
    memcpy(&control_length, encoded + 40, sizeof(control_length));
    struct msghdr message = {.msg_name = (void *)(uintptr_t)name,
                             .msg_namelen = (socklen_t)name_length,
                             .msg_iov = (struct iovec *)(uintptr_t)vectors,
                             .msg_iovlen = (int)vector_count,
                             .msg_control = (void *)(uintptr_t)control,
                             .msg_controllen = (socklen_t)control_length,
                             .msg_flags = 0};
    result = sendmsg((int)argument0, &message, darwin_message_flags(argument2));
    break;
  }
  case 50:
    result = listen((int)argument0, (int)argument1);
    break;
  case 51:
  case 52: {
    struct sockaddr_storage address;
    socklen_t length = sizeof(address);
    result =
        number == 51
            ? getsockname((int)argument0, (struct sockaddr *)&address, &length)
            : getpeername((int)argument0, (struct sockaddr *)&address, &length);
    if (result == 0)
      result = linux_sockaddr((const struct sockaddr *)&address, length,
                              (void *)(uintptr_t)argument1,
                              (uint32_t *)(uintptr_t)argument2);
    break;
  }
  case 54:
  case 55: {
    const int level = darwin_socket_level((int)argument1);
    const int option = darwin_socket_option(level, (int)argument2);
    if (number == 54)
      result =
          setsockopt((int)argument0, level, option,
                     (const void *)(uintptr_t)argument3, (socklen_t)argument4);
    else {
      result = getsockopt((int)argument0, level, option,
                          (void *)(uintptr_t)argument3,
                          (socklen_t *)(uintptr_t)argument4);
      if (result == 0 && level == SOL_SOCKET && option == SO_ERROR &&
          argument3 != 0) {
        int *error = (int *)(uintptr_t)argument3;
        *error = linux_errno(*error);
      }
    }
    break;
  }
  case 57:
    result = fork();
    break;
  case 59:
    result = execve((const char *)(uintptr_t)argument0,
                    (char *const *)(uintptr_t)argument1,
                    (char *const *)(uintptr_t)argument2);
    break;
  case 60:
    _exit((int)argument0);
  case 61:
    result =
        waitpid((pid_t)argument0, (int *)(uintptr_t)argument1, (int)argument2);
    break;
  case 62:
    result = kill((pid_t)argument0, (int)argument1);
    break;
  case 72:
    result = fcntl((int)argument0, (int)argument1,
                   argument1 == F_SETFL ? darwin_open_flags(argument2)
                                        : (int)argument2);
    break;
  case 73:
    result = flock((int)argument0, (int)argument1);
    break;
  case 74:
    result = fsync((int)argument0);
    break;
  case 79: {
    char *output = (char *)(uintptr_t)argument0;
    if (getcwd(output, (size_t)argument1) != NULL)
      result = (long)strlen(output) + 1;
    break;
  }
  case 82:
    result = rename((const char *)(uintptr_t)argument0,
                    (const char *)(uintptr_t)argument1);
    break;
  case 83:
    result = mkdir((const char *)(uintptr_t)argument0, (mode_t)argument1);
    break;
  case 84:
    result = rmdir((const char *)(uintptr_t)argument0);
    break;
  case 87:
    result = unlink((const char *)(uintptr_t)argument0);
    break;
  case 90:
    result = chmod((const char *)(uintptr_t)argument0, (mode_t)argument1);
    break;
  case 109:
    result = setpgid((pid_t)argument0, (pid_t)argument1);
    break;
  case 217:
    result =
        darwin_getdents((int)argument0, (unsigned char *)(uintptr_t)argument1,
                        (size_t)argument2);
    break;
  case 228:
    result = clock_gettime(argument0 == 1 ? CLOCK_MONOTONIC : CLOCK_REALTIME,
                           (struct timespec *)(uintptr_t)argument1);
    break;
  case 232:
    result =
        darwin_epoll_wait((int)argument0, (unsigned char *)(uintptr_t)argument1,
                          (int)argument2, (int)argument3);
    break;
  case 233:
    result =
        darwin_epoll_control((int)argument0, (int)argument1, (int)argument2,
                             (const void *)(uintptr_t)argument3);
    break;
  case 257:
    result = openat(argument0 == -100 ? AT_FDCWD : (int)argument0,
                    (const char *)(uintptr_t)argument1,
                    darwin_open_flags(argument2), (mode_t)argument3);
    break;
  case 262: {
    struct stat information;
    result = fstatat(argument0 == -100 ? AT_FDCWD : (int)argument0,
                     (const char *)(uintptr_t)argument1, &information,
                     (int)argument3);
    if (result == 0) {
      unsigned char *output = (unsigned char *)(uintptr_t)argument2;
      memset(output, 0, 144);
      store_u32(output, 24, (uint32_t)information.st_mode);
      store_i64(output, 48, (int64_t)information.st_size);
      store_i64(output, 88, (int64_t)information.st_mtimespec.tv_sec);
      store_i64(output, 96, (int64_t)information.st_mtimespec.tv_nsec);
    }
    break;
  }
  case 288: {
    struct sockaddr_storage address;
    socklen_t length = sizeof(address);
    const int descriptor = accept(
        (int)argument0, argument1 == 0 ? NULL : (struct sockaddr *)&address,
        argument1 == 0 ? NULL : &length);
    configure_descriptor(descriptor, argument3);
    result = descriptor;
    if (result >= 0 && argument1 != 0 &&
        linux_sockaddr((const struct sockaddr *)&address, length,
                       (void *)(uintptr_t)argument1,
                       (uint32_t *)(uintptr_t)argument2) != 0)
      result = -1;
    break;
  }
  case 291: {
    const int descriptor = kqueue();
    configure_descriptor(descriptor, argument0);
    result = descriptor;
    break;
  }
  case 293: {
    int *descriptors = (int *)(uintptr_t)argument0;
    result = pipe(descriptors);
    if (result == 0) {
      configure_descriptor(descriptors[0], argument1);
      configure_descriptor(descriptors[1], argument1);
    }
    break;
  }
  case 318:
    arc4random_buf((void *)(uintptr_t)argument0, (size_t)argument1);
    result = argument1;
    break;
  default:
    errno = ENOSYS;
    break;
  }
  if (result == -1)
    return -(int64_t)linux_errno(errno);
  return (int64_t)result;
}
