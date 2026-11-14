#ifndef RUNNER_EDITION_H_
#define RUNNER_EDITION_H_

// Native identity selected by APP_EDITION / APP_PRODUCT at build time.
// Flutter channel names and command-line request flags intentionally stay
// under lib/'s and open_requests.h's existing BaoCode protocol.
namespace edition {

constexpr wchar_t kName[] = APP_PRODUCT_NAME;
constexpr wchar_t kDataFolder[] = APP_DATA_FOLDER;
constexpr wchar_t kRegistryRoot[] = APP_REGISTRY_ROOT;
constexpr wchar_t kSingleInstanceMutex[] = APP_MUTEX;
constexpr wchar_t kOpenRequestProperty[] = APP_OPEN_PROPERTY;
constexpr wchar_t kLoginProfile[] = APP_LOGIN_PROFILE;
constexpr wchar_t kWerModule[] = APP_WER_MODULE;

}  // namespace edition

#endif  // RUNNER_EDITION_H_
