#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
int main(int argc, char **argv) {
  if (argc != 2)
    return 2;
  int fd = socket(AF_INET, SOCK_STREAM, 0), yes = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes);
  struct sockaddr_in addr = {.sin_family = AF_INET,
                             .sin_port = htons(atoi(argv[1])),
                             .sin_addr = {.s_addr = htonl(INADDR_LOOPBACK)}};
  if (bind(fd, (void *)&addr, sizeof addr) || listen(fd, 128))
    return 2;
  for (;;) {
    int c = accept(fd, NULL, NULL);
    if (c < 0)
      return 2;
    char buf[8193];
    size_t n = 0;
    char *body = NULL;
    while (n < 8192) {
      ssize_t r = read(c, buf + n, 8192 - n);
      if (r <= 0)
        break;
      n += r;
      buf[n] = 0;
      body = strstr(buf, "\r\n\r\n");
      if (body && n >= (size_t)(body + 4 - buf) + 256) {
        body += 4;
        break;
      }
    }
    if (body && n >= (size_t)(body - buf) + 256) {
      const char *header =
          "HTTP/1.1 200 OK\r\nContent-Length: 256\r\nConnection: close\r\n\r\n";
      char response[512];
      size_t len = strlen(header);
      memcpy(response, header, len);
      memcpy(response + len, body, 256);
      len += 256;
      size_t at = 0;
      while (at < len) {
        ssize_t r = send(c, response + at, len - at, MSG_NOSIGNAL);
        if (r <= 0)
          break;
        at += r;
      }
    }
    close(c);
  }
}
