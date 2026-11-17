// The Windows native messaging host of this product's browser extension
// (browser_extension/). The browser starts it as the generated manifest beside
// it says, and it passes messages between that extension and the app. It waits
// for the app while it is not running, and again once it quits.
//
// Dart has no Unix sockets on Windows: the app (lib/browser/browser_bridge.dart)
// listens on 127.0.0.1, at the port in its port file: "<port> <token>".
// BaoCode's established file is %TEMP%\baocode-browser.port. Abyss's is
// %TEMP%\Abyss-browser-bridge\abyss-browser.port, inside the app's private
// endpoint folder. Any program may connect to loopback, so the host's hello says
// the token. Abyss validates its file's owner and DACL before reading that token;
// BaoCode's established behavior is unchanged.
//
// Both ways a message is the browser's: its length (4 bytes, this
// machine's order), then that much JSON. The host says what goes on with
// the app in messages of its own: {"type":"bridge","connected":…}. It
// quits once the browser lets it go (its input ends).

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <aclapi.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#include "generated_identity.h"

#define MAX_MESSAGE (64 * 1024 * 1024)

static SRWLOCK out_lock = SRWLOCK_INIT;
static SRWLOCK socket_lock = SRWLOCK_INIT;
static SOCKET bao = INVALID_SOCKET;  // The socket to the app, while connected.
static const char* origin = "";
static HANDLE input;
static HANDLE output;

// The browser's input and output: pipes, read and written as they are (no
// text mode's line ends).
static bool read_input(void* buffer, uint32_t size) {
  char* p = static_cast<char*>(buffer);
  while (size > 0) {
    DWORD n = 0;
    if (!ReadFile(input, p, size, &n, nullptr) || n == 0) return false;
    p += n;
    size -= n;
  }
  return true;
}

static bool write_output(const void* buffer, uint32_t size) {
  const char* p = static_cast<const char*>(buffer);
  while (size > 0) {
    DWORD n = 0;
    if (!WriteFile(output, p, size, &n, nullptr) || n == 0) return false;
    p += n;
    size -= n;
  }
  return true;
}

static bool receive_all(SOCKET fd, void* buffer, uint32_t size) {
  char* p = static_cast<char*>(buffer);
  while (size > 0) {
    int n = recv(fd, p, static_cast<int>(size), 0);
    if (n <= 0) return false;
    p += n;
    size -= static_cast<uint32_t>(n);
  }
  return true;
}

static bool send_all(SOCKET fd, const void* buffer, uint32_t size) {
  const char* p = static_cast<const char*>(buffer);
  while (size > 0) {
    int n = send(fd, p, static_cast<int>(size), 0);
    if (n <= 0) return false;
    p += n;
    size -= static_cast<uint32_t>(n);
  }
  return true;
}

// A whole message, by [take]: its text (freed by the caller), nullptr once
// the input ends.
template <typename Take>
static char* read_message(Take take, uint32_t* length) {
  if (!take(length, 4) || *length > MAX_MESSAGE) return nullptr;
  char* text = static_cast<char*>(malloc(*length ? *length : 1));
  if (!text) return nullptr;
  if (!take(text, *length)) {
    free(text);
    return nullptr;
  }
  return text;
}

static bool send_message(SOCKET fd, const char* text, uint32_t length) {
  return send_all(fd, &length, 4) && send_all(fd, text, length);
}

// To the extension, whole messages at a time.
static void to_browser(const char* text, uint32_t length) {
  AcquireSRWLockExclusive(&out_lock);
  if (!write_output(&length, 4) || !write_output(text, length)) ExitProcess(0);
  ReleaseSRWLockExclusive(&out_lock);
}

static void tell_browser(bool connected) {
  const char* text = connected ? "{\"type\":\"bridge\",\"connected\":true}"
                               : "{\"type\":\"bridge\",\"connected\":false}";
  to_browser(text, static_cast<uint32_t>(strlen(text)));
}

static bool port_file_path(wchar_t* path, size_t size,
                           size_t* directory_length = nullptr) {
  if (size < MAX_PATH + 64) return false;
  const DWORD n = GetTempPathW(MAX_PATH + 1, path);
  if (n == 0 || n > MAX_PATH) return false;
  size_t directory_size = 0;
  if (browser_bridge::kIsAbyss) {
    if (browser_bridge::kPortDirectory[0] == 0 ||
        wcscat_s(path, size, browser_bridge::kPortDirectory) != 0 ||
        wcscat_s(path, size, L"\\") != 0) {
      return false;
    }
    directory_size = wcslen(path) - 1;
  }
  if (directory_length != nullptr) *directory_length = directory_size;
  return wcscat_s(path, size, browser_bridge::kPortFile) == 0;
}

// Reject a directory symlink/junction as well as a file symlink. Never follow
// the directory with FILE_FLAG_BACKUP_SEMANTICS before this attribute query.
static bool ordinary_directory(const wchar_t* path, size_t length) {
  wchar_t directory[MAX_PATH + 64];
  if (length >= _countof(directory)) return false;
  wmemcpy(directory, path, length);
  directory[length] = 0;
  const DWORD attributes = GetFileAttributesW(directory);
  return attributes != INVALID_FILE_ATTRIBUTES &&
         (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0 &&
         (attributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0;
}

static bool same_sid(PSID first, PSID second) {
  return IsValidSid(first) && IsValidSid(second) && EqualSid(first, second);
}

static bool well_known_sid(WELL_KNOWN_SID_TYPE type, void* storage) {
  DWORD size = SECURITY_MAX_SID_SIZE;
  return CreateWellKnownSid(type, nullptr, storage, &size) != 0;
}

// A file in a per-user temp directory can still be writable by everyone. Check
// the opened object, not its path: a symlink or a replaced file must not expose
// the token. Only this user, SYSTEM and the built-in administrators are trusted.
// In particular, NULL DACLs and rights for Everyone / ordinary users are not.
static bool abyss_endpoint_allowed(HANDLE file) {
  BY_HANDLE_FILE_INFORMATION information = {};
  if (GetFileType(file) != FILE_TYPE_DISK ||
      !GetFileInformationByHandle(file, &information) ||
      (information.dwFileAttributes &
       (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != 0) {
    return false;
  }

  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return false;
  DWORD user_size = 0;
  GetTokenInformation(token, TokenUser, nullptr, 0, &user_size);
  TOKEN_USER* user = user_size > 0
                         ? static_cast<TOKEN_USER*>(malloc(user_size))
                         : nullptr;
  bool allowed = user != nullptr &&
                 GetTokenInformation(token, TokenUser, user, user_size,
                                     &user_size) != 0;
  CloseHandle(token);
  if (!allowed || user->User.Sid == nullptr) {
    free(user);
    return false;
  }

  BYTE administrators[SECURITY_MAX_SID_SIZE] = {};
  BYTE system[SECURITY_MAX_SID_SIZE] = {};
  allowed = well_known_sid(WinBuiltinAdministratorsSid, administrators) &&
            well_known_sid(WinLocalSystemSid, system);

  PSID owner = nullptr;
  PACL dacl = nullptr;
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (allowed &&
      GetSecurityInfo(file, SE_FILE_OBJECT,
                      OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                      &owner, nullptr, &dacl, nullptr, &descriptor) !=
          ERROR_SUCCESS) {
    allowed = false;
  }
  // A missing or NULL DACL grants access, rather than meaning "no entries".
  if (allowed && (owner == nullptr || dacl == nullptr ||
                  !same_sid(owner, user->User.Sid))) {
    allowed = false;
  }

  ACL_SIZE_INFORMATION acl = {};
  if (allowed &&
      (!GetAclInformation(dacl, &acl, sizeof acl, AclSizeInformation) ||
       acl.AceCount > 1024)) {
    allowed = false;
  }
  for (DWORD index = 0; allowed && index < acl.AceCount; ++index) {
    void* entry = nullptr;
    if (!GetAce(dacl, index, &entry) || entry == nullptr) {
      allowed = false;
      break;
    }
    const ACE_HEADER* header = static_cast<ACE_HEADER*>(entry);
    // Deny ACEs grant nothing; unknown ACE kinds are not silently accepted.
    if (header->AceType == ACCESS_DENIED_ACE_TYPE) continue;
    if (header->AceType != ACCESS_ALLOWED_ACE_TYPE) {
      allowed = false;
      break;
    }
    const ACCESS_ALLOWED_ACE* ace = static_cast<ACCESS_ALLOWED_ACE*>(entry);
    PSID sid = const_cast<DWORD*>(&ace->SidStart);
    if (same_sid(sid, user->User.Sid) || same_sid(sid, system) ||
        same_sid(sid, administrators)) {
      continue;
    }
    const ACCESS_MASK sensitive =
        FILE_READ_DATA | FILE_WRITE_DATA | FILE_APPEND_DATA | FILE_READ_EA |
        FILE_WRITE_EA | FILE_EXECUTE | FILE_READ_ATTRIBUTES | DELETE |
        WRITE_DAC | WRITE_OWNER | READ_CONTROL | STANDARD_RIGHTS_READ |
        STANDARD_RIGHTS_WRITE | GENERIC_READ | GENERIC_WRITE | GENERIC_EXECUTE |
        GENERIC_ALL;
    if ((ace->Mask & sensitive) != 0 || !IsValidSid(sid)) allowed = false;
  }
  if (descriptor != nullptr) LocalFree(descriptor);
  free(user);
  return allowed;
}

// The app's port and token, from its file: false while there is none (the app
// is not running) or it is not whole yet. Abyss does not read one byte of its
// contents until the opened file's identity and ACL have passed.
static bool find_bao(unsigned* port, char* token, size_t size) {
  wchar_t path[MAX_PATH + 64];
  size_t directory_length = 0;
  if (!port_file_path(path, _countof(path), &directory_length)) return false;
  if (browser_bridge::kIsAbyss &&
      !ordinary_directory(path, directory_length)) {
    return false;
  }
  HANDLE file = CreateFileW(
      path, GENERIC_READ | (browser_bridge::kIsAbyss ? READ_CONTROL : 0),
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL | (browser_bridge::kIsAbyss ? FILE_FLAG_OPEN_REPARSE_POINT : 0), nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  if (browser_bridge::kIsAbyss && !abyss_endpoint_allowed(file)) {
    CloseHandle(file);
    return false;
  }
  char text[256];
  DWORD got = 0;
  const BOOL ok = ReadFile(file, text, static_cast<DWORD>(sizeof text - 1),
                           &got, nullptr);
  CloseHandle(file);
  if (!ok) return false;
  text[got] = 0;
  char* end = nullptr;
  const unsigned long value = strtoul(text, &end, 10);
  if (end == text || *end != ' ' || value == 0 || value > 65535) return false;
  // The token is hex: nothing in it needs escaping in the hello's JSON.
  const char* given = end + 1;
  const size_t length = strspn(given, "0123456789abcdef");
  if (length == 0 || length >= size || given[length] != 0) return false;
  memcpy(token, given, length);
  token[length] = 0;
  *port = static_cast<unsigned>(value);
  return true;
}

static SOCKET connect_bao(unsigned port) {
  SOCKET fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (fd == INVALID_SOCKET) return INVALID_SOCKET;
  sockaddr_in address = {};
  address.sin_family = AF_INET;
  address.sin_port = htons(static_cast<u_short>(port));
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (connect(fd, reinterpret_cast<sockaddr*>(&address),
              static_cast<int>(sizeof address)) != 0) {
    closesocket(fd);
    return INVALID_SOCKET;
  }
  return fd;
}

// The app's messages, to the browser; connecting again each time it comes back.
static DWORD WINAPI from_bao(void*) {
  for (;;) {
    unsigned port = 0;
    char token[128];
    if (!find_bao(&port, token, sizeof token)) {
      Sleep(1000);
      continue;
    }
    SOCKET fd = connect_bao(port);
    if (fd == INVALID_SOCKET) {
      Sleep(1000);
      continue;
    }
    // Who it is: the extension's origin, as the browser gave it, and the
    // token, which says the host is one the user started.
    char hello[640];
    const int n = snprintf(hello, sizeof hello,
                           "{\"type\":\"hello\",\"origin\":\"%s\","
                           "\"token\":\"%s\"}",
                           origin, token);
    if (n <= 0 || n >= static_cast<int>(sizeof hello) ||
        !send_message(fd, hello, static_cast<uint32_t>(n))) {
      closesocket(fd);
      Sleep(1000);
      continue;
    }
    AcquireSRWLockExclusive(&socket_lock);
    bao = fd;
    ReleaseSRWLockExclusive(&socket_lock);
    tell_browser(true);
    for (;;) {
      uint32_t length;
      char* text = read_message(
          [fd](void* buffer, uint32_t size) {
            return receive_all(fd, buffer, size);
          },
          &length);
      if (!text) break;
      to_browser(text, length);
      free(text);
    }
    AcquireSRWLockExclusive(&socket_lock);
    bao = INVALID_SOCKET;
    ReleaseSRWLockExclusive(&socket_lock);
    closesocket(fd);
    tell_browser(false);
    Sleep(1000);
  }
}

static bool origin_allowed(const char* argument) {
  if (browser_bridge::kIsAbyss) {
    return strcmp(argument, browser_bridge::kOrigin) == 0;
  }
  // BaoCode's established filtering remains unchanged. Quotes and backslashes
  // have no place in an origin: none is let in the JSON it goes into.
  return strncmp(argument, "chrome-extension://", 19) == 0 &&
         strpbrk(argument, "\"\\") == nullptr;
}

#ifndef ABYSS_BROWSER_HOST_TEST
int main(int argc, char** argv) {
  // The browser's: the extension's origin first, then a window's handle
  // (--parent-window=…).
  for (int i = 1; i < argc; i++) {
    if (strncmp(argv[i], "chrome-extension://", 19) == 0) {
      if (origin_allowed(argv[i])) origin = argv[i];
      break;
    }
  }
  input = GetStdHandle(STD_INPUT_HANDLE);
  output = GetStdHandle(STD_OUTPUT_HANDLE);
  WSADATA wsa;
  if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) return 1;
  tell_browser(false);
  HANDLE thread = CreateThread(nullptr, 0, from_bao, nullptr, 0, nullptr);
  if (!thread) return 1;
  CloseHandle(thread);
  // The extension's messages, to the app: dropped while it is not there
  // (the extension knows, told above).
  for (;;) {
    uint32_t length;
    char* text = read_message(read_input, &length);
    if (!text) ExitProcess(0);
    AcquireSRWLockExclusive(&socket_lock);
    if (bao != INVALID_SOCKET && !send_message(bao, text, length)) {
      // Gone: its reader sees it too, and says so.
      shutdown(bao, SD_BOTH);
    }
    ReleaseSRWLockExclusive(&socket_lock);
    free(text);
  }
}
#endif  // ABYSS_BROWSER_HOST_TEST
