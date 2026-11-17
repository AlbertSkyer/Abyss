// Isolated host endpoint and origin tests. The production main() is excluded,
// so no browser pipes, sockets or processes are opened.
#define ABYSS_BROWSER_HOST_TEST
#include "../host.cpp"

#include <sddl.h>
#include <algorithm>
#include <string>
#include <vector>

namespace {

int failures = 0;
std::wstring base;

void Check(bool condition, const char* name) {
  if (condition) {
    printf("PASS %s\n", name);
  } else {
    printf("FAIL %s\n", name);
    ++failures;
  }
}

std::wstring UserSid() {
  HANDLE token = INVALID_HANDLE_VALUE;
  Check(OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token) != 0,
        "open test token");
  DWORD size = 0;
  GetTokenInformation(token, TokenUser, nullptr, 0, &size);
  std::vector<BYTE> data(size);
  Check(GetTokenInformation(token, TokenUser, data.data(), size, &size) != 0,
        "read test token");
  CloseHandle(token);
  wchar_t* text = nullptr;
  Check(ConvertSidToStringSidW(
            reinterpret_cast<TOKEN_USER*>(data.data())->User.Sid, &text) != 0,
        "format test SID");
  std::wstring result = text == nullptr ? L"" : text;
  if (text != nullptr) LocalFree(text);
  return result;
}

void WritePort(const std::wstring& path) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  Check(file != INVALID_HANDLE_VALUE, "create synthetic port file");
  const char text[] = "54321 aabbccdd";
  DWORD written = 0;
  Check(WriteFile(file, text, sizeof(text) - 1, &written, nullptr) != 0,
        "write synthetic port file");
  CloseHandle(file);
}

bool ReplaceDacl(const std::wstring& path, const std::wstring& dacl) {
  const std::wstring owner = L"O:" + UserSid();
  const std::wstring security = L"D:PAI(" + owner + L")" + dacl;
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
          security.c_str(), SDDL_REVISION_1, &descriptor, nullptr)) {
    return false;
  }
  SECURITY_ATTRIBUTES attributes = {};
  attributes.nLength = sizeof(attributes);
  attributes.lpSecurityDescriptor = descriptor;
  HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE | WRITE_DAC, 0,
                            &attributes, OPEN_EXISTING,
                            FILE_ATTRIBUTE_NORMAL, nullptr);
  const bool result = file != INVALID_HANDLE_VALUE;
  if (result) CloseHandle(file);
  LocalFree(descriptor);
  return result;
}

void SetDacl(const std::wstring& path, const std::wstring& dacl) {
  const std::wstring security = L"D:P" + dacl;
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  Check(ConvertStringSecurityDescriptorToSecurityDescriptorW(
            security.c_str(), SDDL_REVISION_1, &descriptor, nullptr) != 0,
        "parse synthetic DACL");
  PACL acl = nullptr;
  BOOL present = FALSE, defaulted = FALSE;
  Check(GetSecurityDescriptorDacl(descriptor, &present, &acl, &defaulted) != 0 && present, "extract synthetic DACL");
  const DWORD error = SetNamedSecurityInfoW(
      const_cast<wchar_t*>(path.c_str()), SE_FILE_OBJECT,
      DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION, nullptr,
      nullptr, acl, nullptr);
  Check(error == ERROR_SUCCESS, "apply synthetic DACL");
  LocalFree(descriptor);
}

void SetOwner(const std::wstring& path, PSID owner) {  Check(SetNamedSecurityInfoW(const_cast<wchar_t*>(path.c_str()),
                              SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION, owner,
                              nullptr, nullptr, nullptr) == ERROR_SUCCESS,
        "apply synthetic owner");
}

bool EndpointRead() {
  unsigned port = 0;
  char token[128] = {};
  if (!find_bao(&port, token, sizeof(token))) return false;
  Check(port == 54321, "endpoint port");
  Check(strcmp(token, "aabbccdd") == 0, "endpoint token");
  return true;
}

void SetTemp(const std::wstring& value) {
  Check(SetEnvironmentVariableW(L"TEMP", value.c_str()) != 0, "set test TEMP");
  Check(SetEnvironmentVariableW(L"TMP", value.c_str()) != 0, "set test TMP");
}

void EndpointTests() {
  wchar_t current[MAX_PATH] = {};
  Check(GetCurrentDirectoryW(MAX_PATH, current) != 0, "get isolated test root");
  base = std::wstring(current) + L"\\endpoint";
  Check(CreateDirectoryW(base.c_str(), nullptr) != 0 ||
            GetLastError() == ERROR_ALREADY_EXISTS,
        "create isolated endpoint root");
  const std::wstring user = UserSid();
  const std::wstring permissions =
      L"(A;OICI;FA;;;" + user + L")(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)";
  const std::wstring endpoint =
      browser_bridge::kIsAbyss ? base + L"\\Abyss-browser-bridge" : base;
  SetTemp(base);
  if (browser_bridge::kIsAbyss) {
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    const std::wstring security = L"O:" + user + L"D:PAI" + permissions;
    Check(ConvertStringSecurityDescriptorToSecurityDescriptorW(
              security.c_str(), SDDL_REVISION_1, &descriptor, nullptr) != 0,
          "parse endpoint directory security");
    SECURITY_ATTRIBUTES attributes = {};
    attributes.nLength = sizeof(attributes);
    attributes.lpSecurityDescriptor = descriptor;
    Check(CreateDirectoryW(endpoint.c_str(), &attributes) != 0,
          "create secured endpoint directory");
    LocalFree(descriptor);
  }
  const std::wstring path = endpoint + L"\\" +
                            (browser_bridge::kIsAbyss
                                 ? L"abyss-browser.port"
                                 : L"baocode-browser.port");
  if (browser_bridge::kIsAbyss) {
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    const std::wstring security = L"O:" + user + L"D:PAI" + permissions;
    ConvertStringSecurityDescriptorToSecurityDescriptorW(
        security.c_str(), SDDL_REVISION_1, &descriptor, nullptr);
    SECURITY_ATTRIBUTES attributes = {};
    attributes.nLength = sizeof(attributes);
    attributes.lpSecurityDescriptor = descriptor;
    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, &attributes,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    Check(file != INVALID_HANDLE_VALUE, "create private synthetic port file");
    const char text[] = "54321 aabbccdd";
    DWORD written = 0;
    Check(WriteFile(file, text, sizeof(text) - 1, &written, nullptr) != 0,
          "write private synthetic port file");
    CloseHandle(file);
    LocalFree(descriptor);
  } else {
    WritePort(path);
  }

  Check(EndpointRead(), browser_bridge::kIsAbyss
                            ? "Abyss accepts private current-user endpoint"
                            : "BaoCode accepts established temp endpoint");

  if (browser_bridge::kIsAbyss) {
    SetDacl(path, permissions + L"(A;OICI;GRGW;;;WD)");
    Check(!EndpointRead(), "Abyss rejects Everyone read/write");
    SetDacl(path, permissions + L"(A;OICI;FR;;;WD)");
    Check(!EndpointRead(), "Abyss rejects Everyone read");
    SetDacl(path, permissions + L"(A;OICI;FW;;;WD)");
    Check(!EndpointRead(), "Abyss rejects Everyone write");
    SetDacl(path, L"(D;OICI;FW;;;AN)" + permissions);
    Check(EndpointRead(), "Abyss allows non-granting deny ACE");
    SetDacl(path, permissions + L"(A;OICI;GRGW;;;BU)");
    Check(!EndpointRead(), "Abyss rejects ordinary built-in Users access");
    SetDacl(path, permissions + L"(A;OICI;FR;;;BU)");
    Check(!EndpointRead(), "Abyss rejects key-value read access");
    SetDacl(path, L"(A;OICI;GRGW;;;WD)");
    Check(!EndpointRead(), "Abyss rejects DACL without owner grants");

    SetDacl(path, permissions);
    BYTE administrators[SECURITY_MAX_SID_SIZE] = {};
    Check(well_known_sid(WinBuiltinAdministratorsSid, administrators),
          "make test administrator SID");
    const DWORD owner_result = SetNamedSecurityInfoW(const_cast<wchar_t*>(path.c_str()), SE_FILE_OBJECT,
        OWNER_SECURITY_INFORMATION, administrators, nullptr, nullptr, nullptr);
    if (owner_result == ERROR_SUCCESS) {
      Check(!EndpointRead(), "Abyss rejects administrator-owned token file");
    } else {
      printf("SKIP foreign owner setup requires privilege (%lu)\n", owner_result);
    }
    // Restore a valid current user from its string SID before continuing.
    PSID owner = nullptr;
    Check(ConvertStringSidToSidW(user.c_str(), &owner) != 0, "restore SID");
    SetOwner(path, owner);
    LocalFree(owner);
    Check(EndpointRead(), "Abyss accepts restored current-user owner");

    SetDacl(path, L"");
    Check(!EndpointRead(), "Abyss rejects empty DACL");
    Check(SetNamedSecurityInfoW(
              const_cast<wchar_t*>(path.c_str()), SE_FILE_OBJECT,
              DACL_SECURITY_INFORMATION, nullptr, nullptr, nullptr, nullptr) ==
              ERROR_SUCCESS,
          "apply null DACL");
    Check(!EndpointRead(), "Abyss rejects null DACL");

    // Rebuild the ordinary private file after the NULL-DACL case.
    DeleteFileW(path.c_str());
    WritePort(path);
    SetDacl(path, permissions);
    PSID restored = nullptr;
    ConvertStringSidToSidW(user.c_str(), &restored);
    SetOwner(path, restored);
    LocalFree(restored);
    Check(EndpointRead(), "Abyss accepts rebuilt private endpoint");

    // A junction needs no privilege and covers the common local reparse case.
    DeleteFileW(path.c_str());
    RemoveDirectoryW(endpoint.c_str());
    Check(CreateDirectoryW((base + L"\\target").c_str(), nullptr) != 0,
          "create junction target");
    // The command creates only a junction below this isolated test directory;
    // no user directory, product configuration or registry is touched.
    wchar_t command[1024];
    swprintf_s(command, L"cmd.exe /d /c mklink /j \"%s\" \"%s\"",
               endpoint.c_str(), (base + L"\\target").c_str());
    STARTUPINFOW startup = {};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process = {};
    if (CreateProcessW(nullptr, command, nullptr, nullptr, FALSE,
                       CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process)) {
      WaitForSingleObject(process.hProcess, 10000);
      DWORD code = 1;
      GetExitCodeProcess(process.hProcess, &code);
      CloseHandle(process.hThread);
      CloseHandle(process.hProcess);
      Check(code == 0, "create isolated directory junction");
    } else {
      Check(false, "launch isolated junction creation");
    }
    WritePort((base + L"\\target\\abyss-browser.port").c_str());
    SetDacl((base + L"\\target\\abyss-browser.port").c_str(), permissions);
    Check(!EndpointRead(), "Abyss rejects reparse endpoint directory");
    RemoveDirectoryW(endpoint.c_str());
    CreateDirectoryW(endpoint.c_str(), nullptr);
    WritePort(path);
    SetDacl(path, permissions);
    PSID current_owner = nullptr;
    ConvertStringSidToSidW(user.c_str(), &current_owner);
    SetOwner(path, current_owner);
    LocalFree(current_owner);
  }

  const std::wstring directory_file =
      endpoint + L"\\" +
      (browser_bridge::kIsAbyss ? L"abyss-browser.port-as-directory"
                                : L"baocode-browser.port-as-directory");
  Check(CreateDirectoryW(directory_file.c_str(), nullptr) != 0,
        "create ordinary test directory");
  Check(ordinary_directory(directory_file.c_str(), directory_file.size()),
        "ordinary directory check accepts directory");
  Check(!ordinary_directory(path.c_str(), path.size()),
        "ordinary directory check rejects file");

  Check(strcmp(browser_bridge::kExtensionId,
               browser_bridge::kIsAbyss
                   ? "kecjiojfloffimkeghgongilhienkdlh"
                   : "jfjagocghaaheooicmdnhcholmgdkngk") == 0,
        "edition extension identity");
  if (browser_bridge::kIsAbyss) {
    Check(origin_allowed("chrome-extension://kecjiojfloffimkeghgongilhienkdlh/"),
          "Abyss accepts its exact origin");
    Check(!origin_allowed("chrome-extension://kecjiojfloffimkeghgongilhienkdlh"),
          "Abyss rejects missing origin slash");
    Check(!origin_allowed("chrome-extension://kecjiojfloffimkeghgongilhienkdlh/x"),
          "Abyss rejects origin suffix");
    Check(!origin_allowed("chrome-extension://jfjagocghaaheooicmdnhcholmgdkngk/"),
          "Abyss rejects BaoCode origin");
    Check(!origin_allowed("https://kecjiojfloffimkeghgongilhienkdlh/"),
          "Abyss rejects non-extension scheme");
  } else {
    Check(origin_allowed("chrome-extension://jfjagocghaaheooicmdnhcholmgdkngk/"),
          "BaoCode accepts established origin");
    Check(origin_allowed("chrome-extension://another-extension/"),
          "BaoCode origin filtering remains unchanged");
    Check(!origin_allowed("https://jfjagocghaaheooicmdnhcholmgdkngk/"),
          "BaoCode rejects non-extension scheme");
  }
}

}  // namespace

int main() {
  EndpointTests();
  printf("%s (%s): %d failure(s)\n", failures == 0 ? "PASS" : "FAIL",
         browser_bridge::kIsAbyss ? "Abyss" : "BaoCode", failures);
  return failures == 0 ? 0 : 1;
}
