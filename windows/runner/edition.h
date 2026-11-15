#ifndef RUNNER_EDITION_H_
#define RUNNER_EDITION_H_

// Fallback for an editor that has not configured CMake. Native builds use
// the generated header in their own binary directory, never this identity.
namespace edition {
constexpr wchar_t kName[] = L"BaoCode";
constexpr wchar_t kDataFolder[] = L"baocode";
constexpr wchar_t kRegistryRoot[] = L"Software\\BaoCode";
constexpr wchar_t kSingleInstanceMutex[] = L"Local\\BaoCode.SingleInstance";
constexpr wchar_t kOpenRequestProperty[] = L"BaoCode.OpenRequests";
constexpr wchar_t kLoginProfile[] = L"BaoCode-Login";
constexpr wchar_t kWerModule[] = L"baocode_wer.dll";
}  // namespace edition

#endif  // RUNNER_EDITION_H_
